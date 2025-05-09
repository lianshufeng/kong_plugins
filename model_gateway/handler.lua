local cjson = require "cjson.safe"

local plugin = {
  PRIORITY = 1000,
  VERSION = "0.1",
}

-- 本地服务缓存，只在当前 worker 有效
local service_cache = {}

-- 安全地更新服务缓存，使用整表替换避免协程间读写冲突
local function update_service_cache(new_data)
  service_cache = new_data
end

-- 插件初始化函数，在每个 worker 启动时执行一次
function plugin:init_worker()
  kong.log.notice("init_worker: 启动服务缓存定时器")

  -- 定时拉取服务列表并更新缓存的函数
  local function fetch_services(premature)
    if premature then return end  -- 如果是提前终止（如 worker 退出），则直接返回

    kong.log.debug("从 kong.db 拉取服务信息")

    local services, err = kong.db.services:each()
    if err then
      kong.log.err("获取服务失败: ", err)
      return
    end

    local new_cache = {}
    local count = 0

    -- 遍历所有服务，构造新的缓存表
    for svc, err in services do
      if not err then
        new_cache[svc.name] = {
          host = svc.host,
          port = svc.port,
          path = svc.path,
          protocol = svc.protocol or "http", -- 默认使用 http 协议
        }
        count = count + 1
        kong.log.debug("缓存服务: ", svc.name, " -> ", svc.host, ":", svc.port, svc.path or "", " (", svc.protocol, ")")
      end
    end

    -- 替换缓存
    update_service_cache(new_cache)
    kong.log.debug("服务缓存更新完成，共 ", count, " 个服务")
  end

  -- 👇 立即拉取一次服务，避免等待 10 秒
  kong.log.notice("init_worker: 立即执行一次服务拉取")
  fetch_services(false)

  -- 👇 启动定时器，每 10 秒更新一次缓存
  local ok, err = ngx.timer.every(30, fetch_services)
  if not ok then
    kong.log.err("启动服务拉取定时器失败: ", err)
  end
end

-- 可选配置更新函数（当前未使用）
function plugin:configure(configs)
  kong.log.notice("configure handler: 收到 ", (configs and #configs or 0), " 个配置项")
end

-- 访问阶段，判断是否路由到缓存中的服务
function plugin:access(plugin_conf)
  local route = kong.router.get_route()
  if not route or route.name ~= plugin_conf.route_name then
    kong.log.debug("跳过插件: 路由名称不匹配")
    return
  end

  -- 仅处理 POST 请求
  local method = kong.request.get_method()
  if method ~= "POST" then
    return
  end

  -- 获取并解析请求体
  local body = kong.request.get_raw_body()
  if not body then return end

  local json, err = cjson.decode(body)
  if not json then return end

  local model = json.model
  if not model then return end

  local service_name = plugin_conf.service_prefix .. model

  -- 查找服务缓存
  local svc = service_cache[service_name]
  if not svc then
    kong.log.notice("未在缓存中找到匹配服务，模型: ", model)
    return
  end

  -- 设置目标上游服务
  kong.service.set_target(svc.host, svc.port)
  kong.service.request.set_scheme(svc.protocol)

  if svc.path then
    kong.service.request.set_path(svc.path)
  end
  
  
  -- 查找 apikey 并设置 Authorization 头
  kong.service.request.set_header("Authorization","") -- 清空调，防止参数穿
  for _, entry in ipairs(plugin_conf.model_apikey_map or {}) do
    if entry.model == model then
      local token = "Bearer " .. entry.apikey
      kong.service.request.set_header("Authorization", token)
      kong.log.debug("设置 Authorization 头: ", token)
      break
    end
  end
  

  -- 合并后的日志输出
  kong.log.notice("将请求路由到服务: ", service_name, " -> ", svc.host, ":", svc.port, " (", svc.protocol, "), 路径: ", svc.path or "/")

  ngx.ctx.buffered = false
end


-- 响应头过滤阶段，增加标记头
function plugin:header_filter(plugin_conf)
  kong.response.set_header("X-Model-Routed", "true")
end

return plugin
