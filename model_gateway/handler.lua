-- kong/plugins/yourplugin/handler.lua
-- 功能：根据请求体中的 model，路由到对应 Service，并按 model 映射选择 apikey（支持 ","/";" 分隔，优先轮询，异常随机）

local cjson_safe = require "cjson.safe"

-- ================== 常量与别名 ==================
local kong = kong
local ngx  = ngx
local encode = cjson_safe.encode
local decode = cjson_safe.decode

local plugin = {
  PRIORITY = 1000,
  VERSION  = "0.1",
}

-- ================== 内部状态 ==================
local service_cache = {}   -- name -> {host, port, path, protocol}
local rr_state = {}        -- 轮询状态：model -> next index

-- ================== 工具函数 ==================
local function jlog(val)
  return encode(val) or "<unencodable>"
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 支持 "," 或 ";" 分隔；若 apikey 已是数组也兼容
local function normalize_apikeys(apikey_field)
  if not apikey_field then return {} end

  if type(apikey_field) == "table" then
    local t = {}
    for _, v in ipairs(apikey_field) do
      if v and v ~= "" then t[#t+1] = trim(v) end
    end
    return t
  end

  if type(apikey_field) == "string" then
    local arr = {}
    for token in apikey_field:gmatch("[^,;]+") do
      local v = trim(token)
      if v ~= "" then arr[#arr+1] = v end
    end
    return arr
  end

  return {}
end

local function rr_pick(model, keys)
  if #keys == 0 then return nil end
  local i = rr_state[model]
  if not i or i < 1 or i > #keys then i = 1 end
  local chosen = keys[i]
  i = i + 1
  if i > #keys then i = 1 end
  rr_state[model] = i
  return chosen
end

local function rand_pick(keys)
  if #keys == 0 then return nil end
  return keys[math.random(1, #keys)]
end

-- 读取请求体（优先内存；不在内存则尝试磁盘）
local function read_raw_body()
  ngx.req.read_body()
  local body = kong.request.get_raw_body()
  if body then return body end

  local file_path = ngx.req.get_body_file()
  if not file_path then
    kong.log.warn("请求体不在内存且无磁盘文件")
    return nil
  end

  local f, err = io.open(file_path, "rb")
  if not f then
    kong.log.err("打开请求体文件失败: ", err)
    return nil
  end

  local data = f:read("*a")
  f:close()
  return data
end

local function set_upstream_target(svc)
  kong.service.set_target(svc.host, svc.port)
  kong.service.request.set_scheme(svc.protocol or "http")
  if svc.path then
    kong.service.request.set_path(svc.path)
  end
end

local function update_service_cache(new_tbl)
  kong.log.debug("更新服务缓存: ", jlog(new_tbl))
  service_cache = new_tbl
end

-- ================== 生命周期：定时拉取服务 ==================
function plugin:init_worker()
  kong.log.notice("init_worker: 启动服务缓存定时器")

  -- 随机数种子（用于随机兜底更均匀）
  math.randomseed(ngx.now() * 1000 + ngx.worker.pid())

  local function fetch_services(premature)
    if premature then return end

    local iter, err = kong.db.services:each()
    if err then
      kong.log.err("获取服务失败: ", err)
      return
    end

    local new_cache, count = {}, 0
    for svc, iter_err in iter do
      if not iter_err then
        new_cache[svc.name] = {
          host     = svc.host,
          port     = svc.port,
          path     = svc.path,
          protocol = svc.protocol or "http",
        }
        count = count + 1
        kong.log.debug("缓存服务: ", svc.name, " -> ", svc.host, ":", svc.port, svc.path or "", " (", svc.protocol, ")")
      end
    end

    update_service_cache(new_cache)
    kong.log.debug("服务缓存更新完成，共 ", count, " 个服务")
  end

  -- 启动即拉一次
  fetch_services(false)

  -- 每 30s 更新一次
  local ok, err = ngx.timer.every(30, fetch_services)
  if not ok then
    kong.log.err("启动服务拉取定时器失败: ", err)
  end
end

function plugin:configure(configs)
  kong.log.notice("configure: 收到配置项数量 = ", (configs and #configs or 0))
end

-- ================== 主流程 ==================
function plugin:access(conf)
  -- 路由匹配（早返回）
  local route = kong.router.get_route()
  local route_name = route and route.name or nil
  if route_name ~= conf.route_name then
    kong.log.debug("跳过：路由名称不匹配。当前=", route_name or "nil", " 期望=", conf.route_name or "nil")
    return
  end

  -- 仅处理 POST
  if kong.request.get_method() ~= "POST" then
    return
  end

  -- 读取/解析请求体
  local raw = read_raw_body()
  kong.log.debug("请求体原文: ", raw or "nil")
  if not raw then return end

  local json, jerr = decode(raw)
  if not json then
    kong.log.err("JSON 解析失败: ", jerr)
    return
  end

  local model = json.model
  kong.log.debug("请求模型名: ", model or "nil")
  if not model or model == "" then
    return
  end

  -- 按前缀拼接 service 名并命中缓存
  local service_name = (conf.service_prefix or "") .. model
  kong.log.debug("预期服务名: ", service_name)
  local svc = service_cache[service_name]
  if not svc then
    kong.log.debug("服务未命中缓存: ", service_name)
    return
  end

  -- 设置上游目标
  set_upstream_target(svc)

  -- apikey 处理：优先轮询，异常随机；仅当模型匹配到条目时生效
  if conf.model_apikey_map then
    for _, entry in ipairs(conf.model_apikey_map) do
      if entry.model == model then
        -- 支持字符串（逗号/分号分隔）或数组
        local keys = normalize_apikeys(entry.apikey)
        local chosen

        if #keys > 1 then
          chosen = rr_pick(model, keys) or rand_pick(keys)
          kong.log.debug("按轮询选择 apikey（模型维度）")
        elseif #keys == 1 then
          chosen = keys[1]
          kong.log.debug("仅一个 apikey，直接使用")
        else
          kong.log.warn("未提供有效 apikey（为空或格式不正确）")
        end

        -- 设置 Authorization
        if chosen and chosen ~= "" then
          kong.service.request.set_header("Authorization", "Bearer " .. chosen)
          kong.log.debug("设置 Authorization（隐藏具体值）")
        end

        -- 可选：只替换请求体中的模型名
        if entry.newmodel and entry.newmodel ~= model then
          kong.log.debug("替换模型名（仅请求体）: ", model, " -> ", entry.newmodel)
          json.model = entry.newmodel
          local new_body = encode(json)
          if new_body then
            kong.service.request.set_raw_body(new_body)
            kong.log.debug("已更新请求体")
          end
        end

        break
      end
    end
  end

  kong.log.notice("路由到: ", service_name, " -> ", svc.host, ":", svc.port, " (", svc.protocol or "http", ")",
                  " 路径=", svc.path or "/")
  ngx.ctx.buffered = false
end

function plugin:header_filter(_)
  kong.response.set_header("X-Model-Routed", "true")
end

return plugin
