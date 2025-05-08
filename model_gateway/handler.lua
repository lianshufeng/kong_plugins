local cjson = require "cjson.safe"

local plugin = {
  PRIORITY = 1000,
  VERSION = "0.1",
}

local service_cache = {}

local function update_service_cache(new_data)
  for k in pairs(service_cache) do
    service_cache[k] = nil
  end
  for k, v in pairs(new_data) do
    service_cache[k] = v
  end
end

function plugin:init_worker()
  kong.log.notice("init_worker: starting service cache timer")

  local function fetch_services(premature)
    if premature then return end

    kong.log.debug("Fetching services from kong.db")

    local services, err = kong.db.services:each()
    if err then
      kong.log.err("Failed to fetch services: ", err)
      return
    end

    local new_cache = {}
    local count = 0
    for svc, err in services do
      if not err then
        new_cache[svc.name] = {
          host = svc.host,
          port = svc.port,
          path = svc.path,
          protocol = svc.protocol or "http", -- 缓存协议用于日志
        }
        count = count + 1
        kong.log.debug("Cached service: ", svc.name, " -> ", svc.host, ":", svc.port, svc.path or "", " (", svc.protocol, ")")
      end
    end

    update_service_cache(new_cache)
    kong.log.debug("Service cache updated with ", count, " entries")
  end

  local ok, err = ngx.timer.every(10, fetch_services)
  if not ok then
    kong.log.err("Failed to start service fetch timer: ", err)
  end
end

function plugin:configure(configs)
  kong.log.notice("configure handler: got ", (configs and #configs or 0), " configs")
end

function plugin:access(plugin_conf)
  -- 只在路由名匹配时生效
  local route = kong.router.get_route()
  if not route or route.name ~= plugin_conf.route_name then
    kong.log.debug("Skipping plugin: route name mismatch")
    return
  end

  local method = kong.request.get_method()
  if method ~= "POST" then
    return
  end

  local body = kong.request.get_raw_body()
  if not body then
    return
  end

  local json, err = cjson.decode(body)
  if not json then
    return
  end

  local model = json.model
  if not model then
    return
  end

  local service_name = plugin_conf.service_prefix .. model

  local svc = service_cache[service_name]
  if not svc then
    kong.log.notice("No matching service found in cache for model: ", model)
    return
  end

  kong.log.notice("Routing to service: ", service_name, " -> ", svc.host, ":", svc.port, " (", svc.protocol, ")")
  kong.service.set_target(svc.host, svc.port)

  -- 设置协议：默认是 http，只有显式指定为 https 才设置为 https
  -- if svc.protocol == "https" then
    -- kong.log.debug("Setting upstream protocol to HTTPS")
    -- kong.service.set_protocol("https")
  -- else
    -- kong.log.debug("Using default upstream protocol (HTTP)")
    -- kong.service.set_protocol("http")
  -- end

  if svc.path then
    kong.log.notice("Setting request path to: ", svc.path)
    kong.service.request.set_path(svc.path)
  end

  ngx.ctx.buffered = false
end


function plugin:header_filter(plugin_conf)
  kong.response.set_header("X-Model-Routed", "true")
end

return plugin
