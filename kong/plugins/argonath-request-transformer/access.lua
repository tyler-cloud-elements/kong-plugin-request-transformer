-- TRT: Copy of request-transformer-advanced plugin
local multipart = require "multipart"
local cjson = require "cjson"
local pl_template = require "pl.template"
local pl_tablex = require "pl.tablex"
local jwt_decoder = require "kong.plugins.jwt.jwt_parser"

local table_insert = table.insert
local req_set_uri_args = ngx.req.set_uri_args
local req_get_uri_args = ngx.req.get_uri_args
local req_set_header = ngx.req.set_header
local req_get_headers = ngx.req.get_headers
local req_read_body = ngx.req.read_body
local req_set_body_data = ngx.req.set_body_data
local req_get_body_data = ngx.req.get_body_data
local req_clear_header = ngx.req.clear_header
local req_set_method = ngx.req.set_method
local encode_args = ngx.encode_args
local ngx_decode_args = ngx.decode_args
local ngx_log = ngx.log
local type = type
local str_find = string.find
local pcall = pcall
local pairs = pairs
local error = error
local rawset = rawset
local pl_copy_table = pl_tablex.deepcopy

local _M = {}
local template_cache = setmetatable( {}, { __mode = "k" })
local template_environment

local DEBUG = ngx.DEBUG
local CONTENT_LENGTH = "content-length"
local CONTENT_TYPE = "content-type"
local HOST = "host"
local JSON, MULTI, ENCODED = "json", "multi_part", "form_encoded"
local EMPTY = pl_tablex.readonly({})

-- JSON serialization for printing various objects
-- 
-- Arguments:
--  @o: The object to print
-- Returns:
--  The object as string
local function serialize(o)
  if not o then
    return " is null"
  elseif type(o) == 'table' then
     local s = '{ '
     for k,v in pairs(o) do
        if type(k) ~= 'number' then k = '"'..k..'"' end
        s = s .. '['..k..'] = ' .. serialize(v) .. ','
     end
     return s .. '} '
  else
     return tostring(o)
  end
end

-- NPE safe logger
-- 
-- Arguments:
--  @char: String to log
--  @v: Value to log
-- Returns:
--  VOID
local function log(char, v)
  ngx_log(DEBUG, char..serialize(v))
end

-- Attempts to split a value by period. This returns as 2 values:
-- 1st (top level)
-- 2nd (rest)
-- i.e. query.metadata.value -> top = "query", rest = "metadata.value"
-- 
-- Arguments:
--  @: String value
-- Returns:
--    Split string by top and rest
local function splitByPeriod(value)
  if (value) then
    local top, rest = value:match("^([^.]+)%.*(.-)$")
    return top, rest
  end
  return EMPTY
end

-- Check existance via plaintext
-- 
-- Arguments:
--  @stringValue: String value to check
--  @subString: Sub-string to check existance of
-- Returns
--  Boolean
local function stringContains(stringValue, subString)
  if (stringValue and subString) then
    return string.find(stringValue, subString, 1, true) ~= nil
  end

  return false
end

-- Retrieve nested JSON value via dot notation
-- 
-- Arguments:
--  @json: JSON Map to retrieve from
--  @path: Dot Notated JSON path
-- Returns:
--  Value of JSON path or nil
local function getValueFromJsonPath(json, path)
  local value

  if (json and path) then
    if (stringContains(path, ".")) then
      -- This is still nested
      local parent, rest = splitByPeriod(path)
      value = json[parent]
      if (value) then
        return getValueFromJsonPath(value, rest)
      end

      return nil
    else
      -- No longer nested
      return json[path]
    end
  end

  return value
end

-- Safe method to decodes a JWT token
-- 
-- Arguments:
--  @token: The value of the Authorization Bearer header (ideally JWT)
-- Returns:
--  Empty Map or Map of JWT claims/headers
local function getJwtFromAuth(token)
  -- decode token to get roles claim
  local jwt, err = jwt_decoder:new(token)
  if err then
    log("Couldn't get JWT: ", err)
    jwt = {}
  end

  return jwt
end
  
-- Silly function to assign globals to transformation path
-- 
-- Globals:
--  query: The query on the request
--  header: The headers on the request
--  body: The body on the request
--  url: The URL on the request
-- Arguments:
--  @parent: Top level path value, corresponds to request values (query, header, body, jwt, url)
-- Returns:
--  JSON of request value
local function getMapValue(parent, path)
  local map = {}

  if (parent == "query") then
    map = template_environment.query_params
  elseif (parent == "header") then
    map = template_environment.headers
  elseif (parent == "body") then
    -- Schema validation shouldn't allow you to get here...
    req_read_body()
    map = req_get_body_data()
  elseif (parent == "jwt") then
    local jwt = {}
    if (template_environment.headers.Authorization 
        and stringContains(template_environment.headers.Authorization, "Bearer ")) then
      local authorization = template_environment.headers.Authorization
      local token = string.gsub(authorization, "Bearer ", "")
      jwt = getJwtFromAuth(token)
    end
    map = jwt
  elseif (parent == "url") then
    -- Schema validation shouldn't allow you to get here...
    log("URL field is not supported for path, ", path)
  end

  return map
end

-- Retrieves nested value from request variables
-- 
-- Arguments:
--  @path: Dot notation path (i.e. header.Some-Field)
-- Returns:
--  Request value
local function getRequestValue(path)
  local parent, rest = splitByPeriod(path)
  local requestValue

  if (parent) then
    local map = getMapValue(parent, path)
    -- Set global...
    requestValue = getValueFromJsonPath(map, rest)
  end

  return requestValue
end

-- Sets nested value for request variables
-- 
-- Arguments:
--  @json: JSON Map to retrieve from
--  @path: Dot Notated JSON path
--  @value: Value to set in dot notated JSON path
-- Returns:
--  Void
local function setValueFromJsonPath(json, path, value)
  if (json and path and value) then
    if (stringContains(path, ".")) then
      -- This is still nested
      local parent, rest = splitByPeriod(path)
      local newJson = json[parent]
      if (newJson) then
        setValueFromJsonPath(newJson, rest, value)
        return
      end

      json[path] = value
    else
      -- No longer nested
      json[path] = value
    end
  end
end

-- Sets nested value for request variables
-- 
-- Arguments:
--  @path: Dot notation path (i.e. header.Some-Field)
--  @value: Value to set in request fields
-- Returns:
--  Void
local function setRequestValue(path, value)
  local parent, rest = splitByPeriod(path)

  if (parent) then
    if (parent == "query") then
      local querystring = pl_copy_table(template_environment.query_params)
      setValueFromJsonPath(querystring, rest, value)
      req_set_uri_args(querystring)
    elseif (parent == "header") then
      req_set_header(rest, value)
    else
      log("Not supported. Cannot set requestValue for path, ", path)
    end
  else
    log("Cannot set requestValue for path, ", path)
  end
end


local function parse_json(body)
  if body then
    local status, res = pcall(cjson.decode, body)
    if status then
      return res
    end
  end
end

local function decode_args(body)
  if body then
    return ngx_decode_args(body)
  end
  return {}
end

local function get_content_type(content_type)
  if content_type == nil then
    return
  end
  if str_find(content_type:lower(), "application/json", nil, true) then
    return JSON
  elseif str_find(content_type:lower(), "multipart/form-data", nil, true) then
    return MULTI
  elseif str_find(content_type:lower(), "application/x-www-form-urlencoded", nil, true) then
    return ENCODED
  end
end

-- meta table for the sandbox, exposing lazily loaded values
local __meta_environment = {
  __index = function(self, key)
    local lazy_loaders = {
      headers = function(self)
        return req_get_headers() or EMPTY
      end,
      query_params = function(self)
        return req_get_uri_args() or EMPTY
      end,
      uri_captures = function(self)
        return (ngx.ctx.router_matches or EMPTY).uri_captures or EMPTY
      end,
      shared = function(self)
        return ((kong or EMPTY).ctx or EMPTY).shared or EMPTY
      end,
    }
    local loader = lazy_loaders[key]
    if not loader then
      -- we don't have a loader, so just return nothing
      return
    end
    -- set the result on the table to not load again
    local value = loader()
    rawset(self, key, value)
    return value
  end,
  __new_index = function(self)
    error("This environment is read-only.")
  end,
}

template_environment = setmetatable({
  -- here we can optionally add functions to expose to the sandbox, eg:
  -- tostring = tostring,  -- for example
}, __meta_environment)

local function clear_environment(conf)
  rawset(template_environment, "headers", nil)
  rawset(template_environment, "query_params", nil)
  rawset(template_environment, "uri_captures", nil)
  rawset(template_environment, "shared", nil)
end

local function param_value(source_template, config_array)
  if not source_template or source_template == "" then
    return nil
  end

  -- find compiled templates for this plugin-configuration array
  local compiled_templates = template_cache[config_array]
  if not compiled_templates then
    compiled_templates = {}
    -- store it by `config_array` which is part of the plugin `conf` table
    -- it will be GC'ed at the same time as `conf` and hence invalidate the
    -- compiled templates here as well as the cache-table has weak-keys
    template_cache[config_array] = compiled_templates
  end

  -- Find or compile the specific template
  local compiled_template = compiled_templates[source_template]
  if not compiled_template then
    compiled_template = pl_template.compile(source_template)
    compiled_templates[source_template] = compiled_template
  end

  return compiled_template:render(template_environment)
end

local function iter(config_array)
  return function(config_array, i, previous_name, previous_value)
    i = i + 1
    local current_pair = config_array[i]
    if current_pair == nil then -- n + 1
      return nil
    end

    local current_name, current_value = current_pair:match("^([^:]+):*(.-)$")

    if current_value == "" then
      return i, current_name
    end

    local res, err = param_value(current_value, config_array)
    if err then
      return error("[request-transformer] failed to render the template ",
        current_value, ", error:", err)
    end

    ngx_log(DEBUG, "[request-transformer] template `", current_value,
      "` rendered to `", res, "`")

    return i, current_name, res
  end, config_array, 0
end

local function append_value(current_value, value)
  local current_value_type = type(current_value)

  if current_value_type  == "string" then
    return { current_value, value }
  elseif current_value_type  == "table" then
    table_insert(current_value, value)
    return current_value
  else
    return { value }
  end
end

local function transform_headers(conf)
  -- Remove header(s)
  for _, name, value in iter(conf.remove.headers) do
    if template_environment.headers[name] then
      req_clear_header(name)
    end
  end

  -- Rename headers(s)
  for _, old_name, new_name in iter(conf.rename.headers) do
    if template_environment.headers[old_name] then
      local value = template_environment.headers[old_name]
      req_set_header(new_name, value)
      req_clear_header(old_name)
    end
  end

  -- Replace header(s)
  for _, name, value in iter(conf.replace.headers) do
    if template_environment.headers[name] then
      req_set_header(name, value)
      if name:lower() == HOST then -- Host header has a special treatment
        ngx.var.upstream_host = value
      end
    end
  end

  -- Add header(s)
  for _, name, value in iter(conf.add.headers) do
    if not template_environment.headers[name] then
      req_set_header(name, value)
      if name:lower() == HOST then -- Host header has a special treatment
        ngx.var.upstream_host = value
      end
    end
  end

  -- Append header(s)
  for _, name, value in iter(conf.append.headers) do
    if name:lower() ~= HOST then
      req_set_header(name, append_value(req_get_headers()[name], value))
    end
  end
end

local function transform_querystrings(conf)

  if not (#conf.remove.querystring > 0 or #conf.rename.querystring or
          #conf.replace.querystring > 0 or #conf.add.querystring > 0 or
          #conf.append.querystring > 0) then
    return
  end

  local querystring = pl_copy_table(template_environment.query_params)

  -- Remove querystring(s)
  for _, name, value in iter(conf.remove.querystring) do
    querystring[name] = nil
  end

  -- Rename querystring(s)
  for _, old_name, new_name in iter(conf.rename.querystring) do
    local value = querystring[old_name]
    querystring[new_name] = value
    querystring[old_name] = nil
  end

  for _, name, value in iter(conf.replace.querystring) do
    if querystring[name] then
      querystring[name] = value
    end
  end

  -- Add querystring(s)
  for _, name, value in iter(conf.add.querystring) do
    if not querystring[name] then
      querystring[name] = value
    end
  end

  -- Append querystring(s)
  for _, name, value in iter(conf.append.querystring) do
    querystring[name] = append_value(querystring[name], value)
  end
  req_set_uri_args(querystring)
end

local function transform_json_body(conf, body, content_length)
  local removed, renamed, replaced, added, appended = false, false, false, false, false
  local content_length = (body and #body) or 0
  local parameters = parse_json(body)
  if parameters == nil then
    if content_length > 0 then
      return false, nil
    end
    parameters = {}
  end

  if content_length > 0 and #conf.remove.body > 0 then
    for _, name, value in iter(conf.remove.body) do
      parameters[name] = nil
      removed = true
    end
  end

  if content_length > 0 and #conf.rename.body > 0 then
    for _, old_name, new_name in iter(conf.rename.body) do
      local value = parameters[old_name]
      parameters[new_name] = value
      parameters[old_name] = nil
      renamed = true
    end
  end

  if content_length > 0 and #conf.replace.body > 0 then
    for _, name, value in iter(conf.replace.body) do
      if parameters[name] then
        parameters[name] = value
        replaced = true
      end
    end
  end

  if #conf.add.body > 0 then
    for _, name, value in iter(conf.add.body) do
      if not parameters[name] then
        parameters[name] = value
        added = true
      end
    end
  end

  if #conf.append.body > 0 then
    for _, name, value in iter(conf.append.body) do
      local old_value = parameters[name]
      parameters[name] = append_value(old_value, value)
      appended = true
    end
  end

  if removed or renamed or replaced or added or appended then
    return true, cjson.encode(parameters)
  end
end

local function transform_url_encoded_body(conf, body, content_length)
  local renamed, removed, replaced, added, appended = false, false, false, false, false
  local parameters = decode_args(body)

  if content_length > 0 and #conf.remove.body > 0 then
    for _, name, value in iter(conf.remove.body) do
      parameters[name] = nil
      removed = true
    end
  end

  if content_length > 0 and #conf.rename.body > 0 then
    for _, old_name, new_name in iter(conf.rename.body) do
      local value = parameters[old_name]
      parameters[new_name] = value
      parameters[old_name] = nil
      renamed = true
    end
  end

  if content_length > 0 and #conf.replace.body > 0 then
    for _, name, value in iter(conf.replace.body) do
      if parameters[name] then
        parameters[name] = value
        replaced = true
      end
    end
  end

  if #conf.add.body > 0 then
    for _, name, value in iter(conf.add.body) do
      if parameters[name] == nil then
        parameters[name] = value
        added = true
      end
    end
  end

  if #conf.append.body > 0 then
    for _, name, value in iter(conf.append.body) do
      local old_value = parameters[name]
      parameters[name] = append_value(old_value, value)
      appended = true
    end
  end

  if removed or renamed or replaced or added or appended then
    return true, encode_args(parameters)
  end
end

local function transform_multipart_body(conf, body, content_length, content_type_value)
  local removed, renamed, replaced, added, appended = false, false, false, false, false
  local parameters = multipart(body and body or "", content_type_value)

  if content_length > 0 and #conf.rename.body > 0 then
    for _, old_name, new_name in iter(conf.rename.body) do
      if parameters:get(old_name) then
        local value = parameters:get(old_name).value
        parameters:set_simple(new_name, value)
        parameters:delete(old_name)
        renamed = true
      end
    end
  end

  if content_length > 0 and #conf.remove.body > 0 then
    for _, name, value in iter(conf.remove.body) do
      parameters:delete(name)
      removed = true
    end
  end

  if content_length > 0 and #conf.replace.body > 0 then
    for _, name, value in iter(conf.replace.body) do
      if parameters:get(name) then
        parameters:delete(name)
        parameters:set_simple(name, value)
        replaced = true
      end
    end
  end

  if #conf.add.body > 0 then
    for _, name, value in iter(conf.add.body) do
      if not parameters:get(name) then
        parameters:set_simple(name, value)
        added = true
      end
    end
  end

  if removed or renamed or replaced or added or appended then
    return true, parameters:tostring()
  end
end

local function transform_body(conf)
  local content_type_value = req_get_headers()[CONTENT_TYPE]
  local content_type = get_content_type(content_type_value)
  if content_type == nil or #conf.rename.body < 1 and
     #conf.remove.body < 1 and #conf.replace.body < 1 and
     #conf.add.body < 1 and #conf.append.body < 1 then
    return
  end

  -- Call req_read_body to read the request body first
  req_read_body()
  local body = req_get_body_data()
  local is_body_transformed = false
  local content_length = (body and #body) or 0

  if content_type == ENCODED then
    is_body_transformed, body = transform_url_encoded_body(conf, body, content_length)
  elseif content_type == MULTI then
    is_body_transformed, body = transform_multipart_body(conf, body, content_length, content_type_value)
  elseif content_type == JSON then
    is_body_transformed, body = transform_json_body(conf, body, content_length)
  end

  if is_body_transformed then
    req_set_body_data(body)
    req_set_header(CONTENT_LENGTH, #body)
  end
end

local function transform_method(conf)
  if conf.http_method then
    req_set_method(ngx["HTTP_" .. conf.http_method:upper()])
    if conf.http_method == "GET" or conf.http_method == "HEAD" or conf.http_method == "TRACE" then
      local content_type_value = req_get_headers()[CONTENT_TYPE]
      local content_type = get_content_type(content_type_value)
      if content_type == ENCODED then
        -- Also put the body into querystring

        -- Read the body
        req_read_body()
        local body = req_get_body_data()
        local parameters = decode_args(body)

        -- Append to querystring
        local querystring = req_get_uri_args()
        for name, value in pairs(parameters) do
          querystring[name] = value
        end
        req_set_uri_args(querystring)
      end
    end
  end
end

local function transform_uri(conf)
  if conf.replace.uri then

    local res, err = param_value(conf.replace.uri, conf.replace)
    if err then
      return error("[request-transformer] failed to render the template ",
        conf.replace.uri, ", error:", err)
    end

    ngx_log(DEBUG, "[request-transformer] template `", conf.replace.uri,
      "` rendered to `", res, "`")

    if res then
      ngx.var.upstream_uri = res
    end
  end
end

-- Performs any kinds of request transformations
-- 
-- Arguments:
--  @conf: The configuration setup in the plugin
-- Returns:
--  VOID
local function transform_request(conf)
  if conf.transform and #conf.transform > 0 then
     for i, line in ipairs(conf.transform) do
      local from = line.from
      local to = line.to
      log("from: ", from)
      log("to: ", to)

      -- We shouldn't get to this point, but we're not handling arrays here
      if (not stringContains(from, "*") and not stringContains(to, "*")) then
        local fromValue = getRequestValue(from)

        setRequestValue(to, fromValue)
      end
    end
  end
end

function _M.execute(conf)
  clear_environment()
  transform_request(conf)
  transform_uri(conf)
  transform_method(conf)
  transform_headers(conf)
  transform_body(conf)
  transform_querystrings(conf)
end

return _M
