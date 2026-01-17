--[[
===============================================================================
HAProxy Lua Script: Tenant Validation via routedns.io API
Domain: *.dns.routedns.io
With Valkey (Redis-compatible) Caching Backend
===============================================================================
FLOW:
  Client → HAProxy (Lua)
           ├─ Valkey cache hit → instant decision
           └─ Cache miss → HTTPS API call → routedns.io
===============================================================================
DEVICE LIMIT ENFORCEMENT:
  - Each tenant can only connect from ONE device (IP) at a time
  - If tenant connects from 2+ different IPs simultaneously, tenant is BLOCKED
  - Blocked tenants remain blocked for block_duration (default: 30 minutes)
===============================================================================
API Endpoints:
  - /dns/validate.php?code={code}        → Validate tenant
  - /dns/bind-device.php?code={code}     → Bind device
  - /dns/query-handler.php?tenant={code}&domain={domain}
===============================================================================
]]--

-------------------------------------------------------------------------------
-- CONFIGURATION
-------------------------------------------------------------------------------
local CONFIG = {
    api_base = "https://routedns.io",
    validate_path = "/dns/validate.php",
    bind_device_path = "/dns/bind-device.php",
    timeout = 3000,  -- milliseconds for HTTP client
    cache_ttl = 43200,  -- 12 hours for valid tenant cache
    negative_cache_ttl = 3600,  -- 1 hour for failed validations
    -- Device limit settings
    device_session_ttl = 60,       -- 60 seconds - device session window
    max_devices_per_tenant = 1,    -- Maximum allowed devices per tenant
    block_duration = 1800,         -- 30 minutes block for violators
    -- Valkey configuration - using Docker service name
    valkey_host = os.getenv("VALKEY_HOST"),
    valkey_port = 6379,
    valkey_timeout = 1000,  -- milliseconds
    valkey_db = 0,
    valkey_password = os.getenv("VALKEY_PASSWORD"),
}

-------------------------------------------------------------------------------
-- VALKEY CONNECTION POOL
-------------------------------------------------------------------------------
local valkey_pool = {}
local valkey_authenticated = false

-- Send raw RESP command and get response
local function valkey_send_raw(conn, command)
    local ok, err = conn:send(command)
    if not ok then
        return nil, "send_failed: " .. tostring(err)
    end
    
    -- Read response
    local response = ""
    local chunk_size = 4096
    
    for _ = 1, 10 do
        local chunk, read_err = conn:receive(chunk_size)
        if not chunk then
            if read_err == "timeout" or read_err == "wantread" then
                break
            end
            return nil, "receive_failed: " .. tostring(read_err)
        end
        response = response .. chunk
        if #chunk < chunk_size then
            break
        end
    end
    
    return response, nil
end

-- Parse RESP response
local function parse_resp(response)
    if not response or response == "" then
        return nil, "empty_response"
    end
    
    local first_char = response:sub(1, 1)
    
    if first_char == "+" then
        local nl_pos = response:find("\r\n")
        if nl_pos then
            return response:sub(2, nl_pos - 1), nil
        end
        return response:sub(2), nil
        
    elseif first_char == "-" then
        local nl_pos = response:find("\r\n")
        if nl_pos then
            return nil, response:sub(2, nl_pos - 1)
        end
        return nil, response:sub(2)
        
    elseif first_char == ":" then
        local nl_pos = response:find("\r\n")
        if nl_pos then
            return tonumber(response:sub(2, nl_pos - 1)), nil
        end
        return tonumber(response:sub(2)), nil
        
    elseif first_char == "$" then
        local len_end = response:find("\r\n")
        if not len_end then
            return nil, "invalid_resp"
        end
        
        local len = tonumber(response:sub(2, len_end - 1))
        if not len then
            return nil, "invalid_length"
        end
        
        if len == -1 then
            return nil, nil
        end
        
        local data_start = len_end + 2
        local data_end = data_start + len - 1
        
        if data_end > #response then
            return nil, "incomplete_data"
        end
        
        return response:sub(data_start, data_end), nil
        
    elseif first_char == "*" then
        local len_end = response:find("\r\n")
        if not len_end then
            return nil, "invalid_resp"
        end
        
        local array_len = tonumber(response:sub(2, len_end - 1))
        if not array_len then
            return nil, "invalid_array_length"
        end
        
        if array_len == -1 then
            return nil, nil
        end
        
        return array_len, nil
    end
    
    return nil, "unknown_resp_type"
end

-- Authenticate with Valkey
local function valkey_auth(conn)
    local password = CONFIG.valkey_password
    local cmd = "*2\r\n$4\r\nAUTH\r\n$" .. #password .. "\r\n" .. password .. "\r\n"
    
    local response, err = valkey_send_raw(conn, cmd)
    if err then
        return nil, err
    end
    
    local result, parse_err = parse_resp(response)
    if parse_err then
        return nil, parse_err
    end
    
    return result == "OK", nil
end

local function close_valkey_connection()
    if valkey_pool.conn then
        pcall(function() valkey_pool.conn:close() end)
        valkey_pool.conn = nil
        valkey_authenticated = false
    end
end

local function get_valkey_connection()
    -- Try to reuse existing connection
    if valkey_pool.conn and valkey_authenticated then
        return valkey_pool.conn
    end
    
    -- Create new TCP connection to Valkey using core.tcp()
    -- core.tcp() is the correct HAProxy Lua API for TCP connections
    local conn = core.tcp()
    if not conn then
        core.log(core.err, "[tenant-valkey] Failed to create TCP socket")
        return nil
    end
    
    -- Set timeout (in seconds for HAProxy tcp socket)
    conn:settimeout(CONFIG.valkey_timeout / 1000)
    
    -- Connect to Valkey
    local ok, err = conn:connect(CONFIG.valkey_host, CONFIG.valkey_port)
    if not ok then
        core.log(core.warning, "[tenant-valkey] Connection failed to " .. CONFIG.valkey_host .. ":" .. CONFIG.valkey_port .. " - " .. tostring(err))
        return nil
    end
    
    valkey_pool.conn = conn
    valkey_authenticated = false
    
    -- Authenticate if password is set
    if CONFIG.valkey_password and CONFIG.valkey_password ~= "" then
        local auth_result, auth_err = valkey_auth(conn)
        if not auth_result then
            core.log(core.err, "[tenant-valkey] Authentication failed: " .. tostring(auth_err))
            close_valkey_connection()
            return nil
        end
        valkey_authenticated = true
    else
        valkey_authenticated = true
    end
    
    return conn
end

local function valkey_command(...)
    local args = {...}
    if #args == 0 then
        return nil, "no_command"
    end
    
    local conn = get_valkey_connection()
    if not conn then
        return nil, "connection_failed"
    end
    
    -- Build RESP protocol command
    local cmd_parts = {}
    table.insert(cmd_parts, "*" .. #args)
    
    for _, arg in ipairs(args) do
        local arg_str = tostring(arg)
        table.insert(cmd_parts, "$" .. #arg_str)
        table.insert(cmd_parts, arg_str)
    end
    
    local command = table.concat(cmd_parts, "\r\n") .. "\r\n"
    
    local response, err = valkey_send_raw(conn, command)
    if err then
        core.log(core.warning, "[tenant-valkey] Command failed: " .. tostring(err))
        close_valkey_connection()
        return nil, err
    end
    
    return parse_resp(response)
end

-------------------------------------------------------------------------------
-- VALKEY CACHE OPERATIONS
-------------------------------------------------------------------------------
local function cache_get(key)
    local value, err = valkey_command("GET", key)
    
    if err then
        core.log(core.debug, "[tenant-valkey] GET error for key " .. key .. ": " .. tostring(err))
        return nil
    end
    
    if value == nil or value == "" then
        return nil
    end
    
    -- Parse cached value (expecting "true" or "false" strings)
    if value == "true" then
        return true
    elseif value == "false" then
        return false
    end
    
    -- Return raw value for other cases
    return value
end

local function cache_get_raw(key)
    local value, err = valkey_command("GET", key)
    
    if err then
        core.log(core.debug, "[tenant-valkey] GET error for key " .. key .. ": " .. tostring(err))
        return nil
    end
    
    return value
end

local function cache_set(key, value, ttl)
    local value_str
    if type(value) == "boolean" then
        value_str = value and "true" or "false"
    else
        value_str = tostring(value)
    end
    
    local expire_time = ttl or CONFIG.cache_ttl
    local ok, err = valkey_command("SETEX", key, expire_time, value_str)
    
    if err then
        core.log(core.warning, "[tenant-valkey] SETEX error for key " .. key .. ": " .. tostring(err))
        return false
    end
    
    return ok ~= nil
end

local function cache_exists(key)
    local ok, err = valkey_command("EXISTS", key)
    
    if err then
        return false
    end
    
    return ok == 1
end

local function cache_delete(key)
    local ok, err = valkey_command("DEL", key)
    
    if err then
        core.log(core.warning, "[tenant-valkey] DEL error for key " .. key .. ": " .. tostring(err))
        return false
    end
    
    return ok ~= nil
end

local function cache_sadd(key, value, ttl)
    local ok, err = valkey_command("SADD", key, value)
    
    if err then
        core.log(core.warning, "[tenant-valkey] SADD error for key " .. key .. ": " .. tostring(err))
        return false
    end
    
    -- Set expiry on the set
    if ttl then
        valkey_command("EXPIRE", key, ttl)
    end
    
    return ok ~= nil
end

local function cache_scard(key)
    local count, err = valkey_command("SCARD", key)
    
    if err then
        core.log(core.debug, "[tenant-valkey] SCARD error for key " .. key .. ": " .. tostring(err))
        return 0
    end
    
    return count or 0
end

local function cache_sismember(key, value)
    local result, err = valkey_command("SISMEMBER", key, value)
    
    if err then
        return false
    end
    
    return result == 1
end

-------------------------------------------------------------------------------
-- DEVICE LIMIT ENFORCEMENT
-- Key structure:
--   dev:{tenant}        -> SET of active device IPs (TTL: device_session_ttl)
--   blocked:{tenant}    -> "true" if tenant is blocked (TTL: block_duration)
-------------------------------------------------------------------------------

-- Check if tenant is blocked
local function is_tenant_blocked(tenant_code)
    local block_key = "blocked:" .. tenant_code
    local blocked = cache_get(block_key)
    return blocked == true
end

-- Block a tenant for violating device limit
local function block_tenant(tenant_code, reason)
    local block_key = "blocked:" .. tenant_code
    cache_set(block_key, true, CONFIG.block_duration)
    core.log(core.warning, "[tenant-device] BLOCKED tenant: " .. tenant_code .. " - Reason: " .. reason .. " - Duration: " .. CONFIG.block_duration .. "s")
end

-- Check and enforce device limit for tenant
-- Returns: true if allowed, false if blocked
local function check_device_limit(tenant_code, client_ip)
    if not tenant_code or not client_ip then
        return false, "missing_params"
    end
    
    -- First check if tenant is already blocked
    if is_tenant_blocked(tenant_code) then
        core.log(core.info, "[tenant-device] Tenant " .. tenant_code .. " is BLOCKED, rejecting IP: " .. client_ip)
        return false, "tenant_blocked"
    end
    
    local device_key = "dev:" .. tenant_code
    
    -- Check if this IP is already registered for this tenant
    if cache_sismember(device_key, client_ip) then
        -- Same device, refresh TTL and allow
        cache_sadd(device_key, client_ip, CONFIG.device_session_ttl)
        return true, "same_device"
    end
    
    -- Check current device count
    local current_devices = cache_scard(device_key)
    
    if current_devices >= CONFIG.max_devices_per_tenant then
        -- VIOLATION: Tenant trying to connect from another device
        -- Block the tenant immediately
        block_tenant(tenant_code, "Multiple devices detected. Current: " .. current_devices .. ", New IP: " .. client_ip)
        
        -- Clear device tracking (tenant is now blocked anyway)
        cache_delete(device_key)
        
        return false, "device_limit_exceeded"
    end
    
    -- First device or within limit - register this device
    cache_sadd(device_key, client_ip, CONFIG.device_session_ttl)
    core.log(core.info, "[tenant-device] Registered device for tenant: " .. tenant_code .. " IP: " .. client_ip)
    
    return true, "device_registered"
end

-------------------------------------------------------------------------------
-- HTTP CLIENT (HAProxy 3.3+ core.httpclient)
-------------------------------------------------------------------------------
local function https_request(url, method)
    method = method or "GET"
    
    -- HAProxy 3.3+ has core.httpclient() for HTTP/HTTPS requests
    local httpclient = core.httpclient()
    if not httpclient then
        core.log(core.err, "[tenant-http] httpclient not available")
        return nil, "httpclient_not_available"
    end
    
    local params = {
        url = url,
        timeout = CONFIG.timeout,
    }
    
    local response, err
    if method == "GET" then
        response, err = httpclient:get(params)
    elseif method == "POST" then
        response, err = httpclient:post(params)
    else
        return nil, "unsupported_method"
    end
    
    if err then
        core.log(core.warning, "[tenant-http] Request failed: " .. tostring(err))
        return nil, tostring(err)
    end
    
    if not response then
        return nil, "no_response"
    end
    
    -- Check HTTP status
    local status = response:get_status()
    if status ~= 200 then
        core.log(core.warning, "[tenant-http] HTTP " .. status .. " for URL: " .. url)
        return nil, "http_" .. status
    end
    
    -- Get response body
    local body = response:get_body()
    return body, nil
end

-- Parse JSON response (simple parser for {"valid":true/false} format)
local function parse_json_bool(json_str, key)
    if not json_str or json_str == "" then
        return nil
    end
    
    -- Match "key":true or "key":false
    local pattern = '"' .. key .. '"%s*:%s*(true|false)'
    local value = json_str:match(pattern)
    
    if value == "true" then
        return true
    elseif value == "false" then
        return false
    end
    
    -- Also try to match "key":"1" or "key":"0" or "key":1
    pattern = '"' .. key .. '"%s*:%s*"?([01])"?'
    value = json_str:match(pattern)
    
    if value == "1" then
        return true
    elseif value == "0" then
        return false
    end
    
    return nil
end

-------------------------------------------------------------------------------
-- VALIDATE TENANT (with HTTPS fallback)
-------------------------------------------------------------------------------
local function validate_tenant_api(tenant_code)
    if not tenant_code or tenant_code == "" then
        return false
    end
    
    -- Sanitize: alphanumeric, hyphens, and underscores only
    if not tenant_code:match("^[%w%-_]+$") then
        core.log(core.warning, "[tenant] Invalid format: " .. tenant_code)
        return false
    end
    
    local cache_key = "v:" .. tenant_code
    
    -- STEP 1: Check Valkey cache first (instant decision)
    local cached = cache_get(cache_key)
    if cached ~= nil then
        core.log(core.debug, "[tenant] ✓ Valkey cache HIT: " .. tenant_code .. " = " .. tostring(cached))
        return cached
    end
    
    core.log(core.debug, "[tenant] ✗ Valkey cache MISS: " .. tenant_code .. " → calling API")
    
    -- STEP 2: Cache miss → HTTPS API call to routedns.io
    local url = CONFIG.api_base .. CONFIG.validate_path .. "?code=" .. tenant_code
    local response_body, http_err = https_request(url, "GET")
    
    if http_err then
        core.log(core.warning, "[tenant] API call failed for " .. tenant_code .. ": " .. http_err)
        -- On API error, use short negative cache (fail secure)
        cache_set(cache_key, false, CONFIG.negative_cache_ttl)
        return false
    end
    
    -- STEP 3: Parse API response
    local is_valid = parse_json_bool(response_body, "valid")
    
    if is_valid == nil then
        -- Try alternative response formats
        is_valid = parse_json_bool(response_body, "success")
        if is_valid == nil then
            is_valid = parse_json_bool(response_body, "status")
        end
    end
    
    -- Default to false if we can't parse
    if is_valid == nil then
        core.log(core.warning, "[tenant] Could not parse API response for " .. tenant_code .. ": " .. (response_body or "nil"))
        is_valid = false
    end
    
    -- STEP 4: Cache the result
    local ttl = is_valid and CONFIG.cache_ttl or CONFIG.negative_cache_ttl
    cache_set(cache_key, is_valid, ttl)
    
    core.log(core.info, "[tenant] API validated " .. tenant_code .. " = " .. tostring(is_valid) .. " (cached for " .. ttl .. "s)")
    
    return is_valid
end

-------------------------------------------------------------------------------
-- BIND DEVICE (with HTTPS support)
-------------------------------------------------------------------------------
local function bind_device_api(tenant_code, client_ip)
    if not tenant_code or tenant_code == "" then
        return false
    end
    
    local cache_key = "b:" .. tenant_code .. ":" .. (client_ip or "")
    
    -- Check cache first
    if cache_exists(cache_key) then
        core.log(core.debug, "[tenant] Device already bound (cached): " .. tenant_code)
        return true
    end
    
    -- Call bind device API
    local url = CONFIG.api_base .. CONFIG.bind_device_path .. "?code=" .. tenant_code
    if client_ip then
        url = url .. "&ip=" .. client_ip
    end
    
    local response_body, http_err = https_request(url, "GET")
    
    if http_err then
        core.log(core.debug, "[tenant] Device bind API failed: " .. tenant_code .. " - " .. http_err)
        return false
    end
    
    -- Cache successful bind
    cache_set(cache_key, true, CONFIG.cache_ttl)
    core.log(core.info, "[tenant] Device bound via API: " .. tenant_code .. " IP: " .. (client_ip or "unknown"))
    
    return true
end

-------------------------------------------------------------------------------
-- HAPROXY ACTION: validate_tenant
-------------------------------------------------------------------------------
core.register_action("validate_tenant", {"tcp-req"}, function(txn)
    local tenant_code = txn:get_var("txn.tenant_code")
    local client_ip = txn.f:src()
    
    -- Default: invalid (fail secure)
    txn:set_var("txn.tenant_valid", 0)
    txn:set_var("txn.block_reason", "")
    
    if not tenant_code or tenant_code == "" then
        core.log(core.warning, "[tenant] No tenant code from IP: " .. (client_ip or "unknown"))
        txn:set_var("txn.block_reason", "no_tenant_code")
        return
    end
    
    -- STEP 1: Check if tenant is blocked (multi-device violation)
    if is_tenant_blocked(tenant_code) then
        core.log(core.warning, "[tenant] BLOCKED (multi-device): " .. tenant_code .. " from " .. (client_ip or "unknown"))
        txn:set_var("txn.block_reason", "multi_device_blocked")
        return
    end
    
    -- STEP 2: Validate tenant code
    local is_valid = validate_tenant_api(tenant_code)
    
    if not is_valid then
        core.log(core.warning, "[tenant] REJECTED (invalid): " .. tenant_code .. " from " .. (client_ip or "unknown"))
        txn:set_var("txn.block_reason", "invalid_tenant")
        return
    end
    
    -- STEP 3: Check device limit (1 tenant = 1 device)
    local device_allowed, device_reason = check_device_limit(tenant_code, client_ip)
    
    if not device_allowed then
        core.log(core.warning, "[tenant] REJECTED (device limit): " .. tenant_code .. " from " .. (client_ip or "unknown") .. " - " .. device_reason)
        txn:set_var("txn.block_reason", device_reason)
        return
    end
    
    -- All checks passed - allow connection
    txn:set_var("txn.tenant_valid", 1)
    core.log(core.info, "[tenant] ALLOWED: " .. tenant_code .. " from " .. (client_ip or "unknown") .. " (" .. device_reason .. ")")
end)

-------------------------------------------------------------------------------
-- HAPROXY ACTION: unblock_tenant (for admin use via stats socket)
-------------------------------------------------------------------------------
core.register_action("unblock_tenant", {"http-req"}, function(txn)
    local tenant_code = txn.sf:req_hdr("X-Tenant-Code")
    
    if not tenant_code or tenant_code == "" then
        return
    end
    
    local block_key = "blocked:" .. tenant_code
    local device_key = "dev:" .. tenant_code
    
    cache_delete(block_key)
    cache_delete(device_key)
    
    core.log(core.info, "[tenant-admin] Unblocked tenant: " .. tenant_code)
end)

-------------------------------------------------------------------------------
-- STARTUP
-------------------------------------------------------------------------------
core.log(core.info, "[tenant] ═══════════════════════════════════════════════════")
core.log(core.info, "[tenant] Lua validation script loaded (HAProxy 3.3+ HTTPS)")
core.log(core.info, "[tenant] API: " .. CONFIG.api_base)
core.log(core.info, "[tenant] Cache TTL: " .. CONFIG.cache_ttl .. "s (valid), " .. CONFIG.negative_cache_ttl .. "s (invalid)")
core.log(core.info, "[tenant] Device limit: " .. CONFIG.max_devices_per_tenant .. " device(s) per tenant")
core.log(core.info, "[tenant] Block duration: " .. CONFIG.block_duration .. "s")
core.log(core.info, "[tenant] ═══════════════════════════════════════════════════")