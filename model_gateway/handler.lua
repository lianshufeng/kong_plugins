local cjson = require "cjson.safe"

local plugin = {
  PRIORITY = 1000,
  VERSION = "0.1",
}

local service_cache = {}

local function update_service_cache(new_data)
  kong.log.debug("更新服务缓存: ", cjson.encode(new_data))
  service_cache = new_data
end

function plugin:init_worker()
  kong.log.notice("init_worker: 启动服务缓存定时器")

  local function fetch_services(premature)
    if premature then return end

    kong.log.debug("从 kong.db 拉取服务信息")

    local services, err = kong.db.services:each()
    if err then
      kong.log.err("获取服务失败: ", err)
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
          protocol = svc.protocol or "http",
        }
        count = count + 1
        kong.log.debug("缓存服务: ", svc.name, " -> ", svc.host, ":", svc.port, svc.path or "", " (", svc.protocol, ")")
      end
    end

    update_service_cache(new_cache)
    kong.log.debug("服务缓存更新完成，共 ", count, " 个服务")
  end

  kong.log.notice("init_worker: 立即执行一次服务拉取")
  fetch_services(false)

  local ok, err = ngx.timer.every(30, fetch_services)
  if not ok then
    kong.log.err("启动服务拉取定时器失败: ", err)
  end
end

function plugin:configure(configs)
  kong.log.notice("configure handler: 收到 ", (configs and #configs or 0), " 个配置项")
end

function plugin:access(plugin_conf)
  local route = kong.router.get_route()
  kong.log.debug("当前路由: ", route and route.name or "nil")
  kong.log.debug("配置期望路由: ", plugin_conf.route_name)
  if not route or route.name ~= plugin_conf.route_name then
    kong.log.debug("跳过插件: 路由名称不匹配")
    return
  end

  local method = kong.request.get_method()
  kong.log.debug("请求方法: ", method)
  if method ~= "POST" then
    return
  end

  ngx.req.read_body()
  local body = kong.request.get_raw_body()

  if not body then
    kong.log.debug("请求体未在内存中，尝试从磁盘读取")
    local file_path = ngx.req.get_body_file()
    if file_path then
      local f, err = io.open(file_path, "rb")
      if f then
        body = f:read("*all")
        f:close()
        kong.log.debug("成功从磁盘读取请求体")
      else
        kong.log.err("打开请求体文件失败: ", err)
      end
    else
      kong.log.warn("请求体既不在内存中，也没有磁盘文件")
    end
  end

  kong.log.debug("请求体原文: ", body or "nil")
  if not body then return end

  local json, err = cjson.decode(body)
  if not json then
    kong.log.err("JSON 解析失败: ", err)
    return
  end

  local model = json.model
  kong.log.debug("请求模型名: ", model or "nil")
  if not model then return end

  local service_name = plugin_conf.service_prefix .. model
  kong.log.debug("预期服务名: ", service_name)

  local svc = service_cache[service_name]
  if not svc then
    kong.log.debug("未在缓存中找到匹配服务，模型: ", model)
    return
  end

  kong.service.set_target(svc.host, svc.port)
  kong.service.request.set_scheme(svc.protocol)

  if svc.path then
    kong.service.request.set_path(svc.path)
  end

  kong.log.debug("插件配置中 apikey 映射表: ", cjson.encode(plugin_conf.model_apikey_map or {}))

  for _, entry in ipairs(plugin_conf.model_apikey_map or {}) do
    kong.log.debug("遍历 apikey 映射: 模型=", entry.model, ", key=", entry.apikey)
    if entry.model == model then
      -- 设置 Authorization 头
      if entry.apikey then
        local token = "Bearer " .. entry.apikey
        kong.service.request.set_header("Authorization", token)
        kong.log.debug("设置 Authorization 头: ", token)
      end

      -- 替换请求体中的模型名（仅限于请求体）
      if entry.newmodel then
        kong.log.debug("替换模型名（仅请求体）: ", model, " -> ", entry.newmodel)
        json.model = entry.newmodel
        local new_body = cjson.encode(json)
        kong.service.request.set_raw_body(new_body)
        kong.log.debug("已更新请求体: ", new_body)
      end

      break
    end
  end

  kong.log.notice("将请求路由到服务: ", service_name, " -> ", svc.host, ":", svc.port, " (", svc.protocol, "), 路径: ", svc.path or "/")
  ngx.ctx.buffered = false
end


function plugin:header_filter(plugin_conf)
  kong.response.set_header("X-Model-Routed", "true")
end

return plugin
