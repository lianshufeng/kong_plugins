-- 引入 Kong 提供的类型定义工具
local typedefs = require "kong.db.schema.typedefs"

-- 插件名称定义
local PLUGIN_NAME = "model_gateway"

-- 插件配置 schema 定义
local schema = {
  name = PLUGIN_NAME,

  -- 插件作用范围和协议
  fields = {
    { consumer = typedefs.no_consumer },  -- 插件不能配置在 consumer 上
    { protocols = typedefs.protocols_http },  -- 插件仅支持 HTTP 和 HTTPS 协议

    -- 插件的 config 区域是自定义配置部分
    { config = {
        type = "record",
        fields = {

          -- 服务名前缀，最终服务名为前缀 + 模型名，默认值为 "model_"
          { service_prefix = {
              type = "string",
              required = true,
              default = "model_",
            }
          },

          -- 路由名称，默认值为 "model_api"
          { route_name = {
              type = "string",
              required = true,
              default = "model_api",
            }
          },

          -- 模型与 API Key 的映射关系数组，每一项包含 model 和 apikey 两个字符串字段
          { model_apikey_map = {
              type = "array",
              required = true,
              default = {},  -- 默认是空数组
              elements = {
                type = "record",
                fields = {
                  { model = { type = "string", required = true } },  -- 模型名称
                  { apikey = { type = "string", required = false } }, -- 对应 API Key
				  { newmodel = { type = "string", required = false } }, -- 需更换的新模型
                }
              }
            }
          },

        },
      },
    },
  },
}

-- 返回 schema 定义给 Kong 使用
return schema
