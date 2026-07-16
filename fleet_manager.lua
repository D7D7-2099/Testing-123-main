--[[
    ============================================
    EXOTIC HUB - FLEET MANAGER
    Multi-Account Management System
    ============================================
    
    Links multiple accounts across different devices
    via JSONBin.io relay. Allows viewing inventory,
    prices, totals, and sending items from all
    accounts to a designated main account.
    
    Usage: Called from main script with references
    to existing systems.
    ============================================
]]

local FleetManager = {}

-- ============================================
-- SECTION 1: INITIALIZATION
-- ============================================

function FleetManager.Init(refs)
    -- Store references to existing systems
    local y = refs.Services       -- game services (y)
    local Z = refs.Systems        -- existing systems (Z)
    local X = refs.Settings       -- settings table (X)
    local g = refs.Helpers        -- helper functions (g)
    local r = refs.Http           -- HTTP utilities (r)
    local T = refs.Library        -- UI Library (T)
    local d = refs.Window         -- Window (d)
    local a = refs.ConfigSave     -- Config/Save (a)
    local E = refs.Modules        -- Extra modules (E)
    local u = refs.IsHeadless     -- headless mode flag

    -- ============================================
    -- SECTION 2: FLEET STATE
    -- ============================================
    
    local Fleet = {
        Connected = false,
        BinId = "",
        MasterKey = "",
        FleetCode = "",
        Role = "worker",           -- "controller" or "worker"
        Data = nil,                 -- cached fleet data
        LastSync = 0,
        LastHeartbeat = 0,
        LastCommandCheck = 0,
        SendLog = {},
        TotalSentValue = 0,
        SenderBusy = false,
        StatusText = "",
        UiRefs = {},
        AccountListLabels = {},
    }

    -- ============================================
    -- SECTION 3: JSONBIN.IO HTTP LAYER
    -- ============================================

    local JsonBin = {}

    -- Get HTTP request function (from existing code pattern)
    JsonBin.GetRequestFunc = function()
        return type(syn) == "table" and syn.request
            or type(http) == "table" and http.request
            or type(http_request) == "function" and http_request
            or type(request) == "function" and request
            or type(fluxus) == "table" and fluxus.request
            or type(krnl) == "table" and krnl.request
    end

    -- Generic HTTP request
    JsonBin.Request = function(method, url, body, extraHeaders)
        local reqFunc = JsonBin.GetRequestFunc()
        if type(reqFunc) ~= "function" then
            -- Fallback to HttpService for GET/POST only
            if method == "GET" then
                local ok, result = pcall(function()
                    return game:HttpGet(url)
                end)
                if ok then
                    return true, 200, result
                end
                return false, 0, "", tostring(result)
            end
            return false, 0, "", "No HTTP request function available"
        end

        local headers = {
            ["Content-Type"] = "application/json",
            ["X-Master-Key"] = Fleet.MasterKey,
        }
        if extraHeaders then
            for k, v in pairs(extraHeaders) do
                headers[k] = v
            end
        end

        local reqBody = {
            Url = url,
            Method = method,
            Headers = headers,
        }
        if body then
            if type(body) == "table" then
                local ok, encoded = pcall(y.HttpService.JSONEncode, y.HttpService, body)
                if not ok then return false, 0, "", "JSON encode failed" end
                reqBody.Body = encoded
            else
                reqBody.Body = body
            end
        end

        local ok, response = pcall(reqFunc, reqBody)
        if not ok then
            return false, 0, "", tostring(response)
        end
        if type(response) ~= "table" then
            return false, 0, "", "Invalid response"
        end

        local statusCode = tonumber(response.StatusCode or response.Status or response.status_code) or 0
        local respBody = response.Body or response.body or ""
        respBody = type(respBody) == "string" and respBody or tostring(respBody or "")
        local success = statusCode >= 200 and statusCode < 300

        return success, statusCode, respBody
    end

    -- Create a new JSONBin
    JsonBin.CreateBin = function(initialData)
        local url = "https://api.jsonbin.io/v3/b"
        local ok, status, body = JsonBin.Request("POST", url, initialData, {
            ["X-Bin-Name"] = "ExoFleet_" .. Fleet.FleetCode,
            ["X-Bin-Private"] = "true",
        })
        if not ok then
            return nil, "Failed to create bin: HTTP " .. tostring(status)
        end
        local decOk, decoded = pcall(y.HttpService.JSONDecode, y.HttpService, body)
        if not decOk or type(decoded) ~= "table" then
            return nil, "Invalid create response"
        end
        local binId = decoded.metadata and decoded.metadata.id
        if not binId then
            return nil, "No bin ID in response"
        end
        return binId, nil
    end

    -- Read fleet data from JSONBin
    JsonBin.ReadBin = function(binId)
        local url = "https://api.jsonbin.io/v3/b/" .. binId .. "/latest"
        local ok, status, body = JsonBin.Request("GET", url)
        if not ok then
            return nil, "Failed to read bin: HTTP " .. tostring(status)
        end
        local decOk, decoded = pcall(y.HttpService.JSONDecode, y.HttpService, body)
        if not decOk or type(decoded) ~= "table" then
            return nil, "Invalid read response"
        end
        -- JSONBin v3 wraps data in .record
        return decoded.record or decoded, nil
    end

    -- Update fleet data in JSONBin
    JsonBin.UpdateBin = function(binId, data)
        local url = "https://api.jsonbin.io/v3/b/" .. binId
        local ok, status, body = JsonBin.Request("PUT", url, data)
        if not ok then
            return false, "Failed to update bin: HTTP " .. tostring(status)
        end
        return true, nil
    end

    -- ============================================
    -- SECTION 4: PRICING ENGINE
    -- ============================================

    local Pricing = {}

    -- Format price as readable string (k, M, B, T)
    Pricing.FormatPrice = function(value)
        value = math.max(math.floor(tonumber(value) or 0), 0)
        if value >= 1e12 then
            return string.format("%.2fT", value / 1e12)
        elseif value >= 1e9 then
            return string.format("%.2fB", value / 1e9)
        elseif value >= 1e6 then
            return string.format("%.2fM", value / 1e6)
        elseif value >= 1e3 then
            return string.format("%.1fK", value / 1e3)
        end
        return tostring(value)
    end

    -- Get estimated price for a single fruit (x1 sell value)
    Pricing.GetFruitPrice = function(fruitName, sourceData, mutation)
        if type(Z.BuySelectFruit) ~= "table" or type(Z.BuySelectFruit.GetEstimatedPriceBuySelectFruit) ~= "function" then
            -- Fallback to SellValueData
            if type(y.SellValueData) == "table" then
                local baseVal = tonumber(y.SellValueData[fruitName]) or 0
                return math.max(math.floor(baseVal), 0), 1, "fallback"
            end
            return 0, 1, "none"
        end
        local price, multiplier, tier = Z.BuySelectFruit.GetEstimatedPriceBuySelectFruit(
            tostring(fruitName or ""),
            type(sourceData) == "table" and sourceData or {},
            tostring(mutation or "")
        )
        return math.max(math.floor(tonumber(price) or 0), 0), tonumber(multiplier) or 1, tostring(tier or "normal")
    end

    -- Get price for a backpack fruit tool
    Pricing.GetToolPrice = function(tool)
        if type(Z.BackpackFruitPriceEsp) ~= "table" or type(Z.BackpackFruitPriceEsp.GetToolPriceBackpackFruitPriceEsp) ~= "function" then
            return 0, 1, "none"
        end
        return Z.BackpackFruitPriceEsp.GetToolPriceBackpackFruitPriceEsp(tool)
    end

    -- ============================================
    -- SECTION 5: INVENTORY REPORTER
    -- ============================================

    local Inventory = {}

    -- Collect full inventory with prices
    Inventory.CollectInventorySummary = function()
        local summary = {
            total_fruit_value = 0,
            total_fruit_count = 0,
            total_pet_count = 0,
            total_seed_count = 0,
            total_gear_count = 0,
            fruits = {},
            pets = {},
            seeds = {},
            gear = {},
        }

        -- Ensure fruit stock data is loaded for pricing
        if type(Z.BuySelectFruit) == "table" and type(Z.BuySelectFruit.EnsureFruitStockReadyBuySelectFruit) == "function" then
            pcall(function() Z.BuySelectFruit.EnsureFruitStockReadyBuySelectFruit(false) end)
        end

        -- Get full inventory
        local invData = nil
        if type(Z.GameApi) == "table" and type(Z.GameApi.GetInventoryDataGameApi) == "function" then
            local ok, data = pcall(Z.GameApi.GetInventoryDataGameApi)
            if ok then invData = data end
        end

        if type(invData) ~= "table" then
            return summary
        end

        -- Process Fruits
        local fruitBuckets = {}
        if type(invData.HarvestedFruits) == "table" then
            for _, fruit in ipairs(invData.HarvestedFruits) do
                local name = tostring(fruit.name or "")
                local weight = tonumber(fruit.weight) or 0
                local mutation = tostring(fruit.mutation or "")
                local variant = tostring(fruit.variant or "Normal")

                -- Calculate price
                local sourceData = {
                    SizeMultiplier = fruit.SizeMultiplier or fruit.size or 1,
                    DecayAlpha = fruit.DecayAlpha,
                    Mutation = mutation,
                }
                local price = Pricing.GetFruitPrice(name, sourceData, mutation)

                summary.total_fruit_count = summary.total_fruit_count + 1
                summary.total_fruit_value = summary.total_fruit_value + price

                if not fruitBuckets[name] then
                    fruitBuckets[name] = {
                        name = name,
                        count = 0,
                        total_value = 0,
                        total_weight = 0,
                        min_weight = weight,
                        max_weight = weight,
                    }
                end
                local bucket = fruitBuckets[name]
                bucket.count = bucket.count + 1
                bucket.total_value = bucket.total_value + price
                bucket.total_weight = bucket.total_weight + weight
                if weight < bucket.min_weight then bucket.min_weight = weight end
                if weight > bucket.max_weight then bucket.max_weight = weight end
            end
        end

        -- Convert fruit buckets to sorted list
        for _, bucket in pairs(fruitBuckets) do
            bucket.avg_weight = bucket.count > 0 and math.floor(bucket.total_weight / bucket.count * 100 + 0.5) / 100 or 0
            table.insert(summary.fruits, bucket)
        end
        table.sort(summary.fruits, function(a, b)
            return a.total_value > b.total_value
        end)

        -- Process Pets
        if type(invData.Pets) == "table" then
            local petBuckets = {}
            for _, pet in ipairs(invData.Pets) do
                local name = tostring(pet.display_name or pet.name or "")
                local rarity = tostring(pet.rarity or "Unknown")
                local variant = tostring(pet.variant or "Normal")
                local size = tostring(pet.size or "Normal")
                local key = name .. "|" .. rarity .. "|" .. variant .. "|" .. size
                if not petBuckets[key] then
                    petBuckets[key] = {
                        name = name,
                        rarity = rarity,
                        variant = variant,
                        size = size,
                        count = 0,
                    }
                end
                petBuckets[key].count = petBuckets[key].count + 1
                summary.total_pet_count = summary.total_pet_count + 1
            end
            for _, bucket in pairs(petBuckets) do
                table.insert(summary.pets, bucket)
            end
            table.sort(summary.pets, function(a, b)
                local rr = g.RarityRank or {}
                local ra = rr[a.rarity] or 0
                local rb = rr[b.rarity] or 0
                if ra ~= rb then return ra > rb end
                return a.count > b.count
            end)
        end

        -- Process Seeds
        if type(Z.GameApi) == "table" and type(Z.GameApi.GetSeedsGameApi) == "function" then
            local ok, seeds = pcall(Z.GameApi.GetSeedsGameApi)
            if ok and type(seeds) == "table" then
                for _, seed in ipairs(seeds) do
                    summary.total_seed_count = summary.total_seed_count + (seed.count or 0)
                    table.insert(summary.seeds, {
                        name = tostring(seed.name or ""),
                        rarity = tostring(seed.rarity or "Unknown"),
                        count = seed.count or 0,
                    })
                end
            end
        end

        -- Process Gear
        if type(Z.GameApi) == "table" and type(Z.GameApi.GetGearGameApi) == "function" then
            local ok, gear = pcall(Z.GameApi.GetGearGameApi)
            if ok and type(gear) == "table" then
                for _, item in ipairs(gear) do
                    summary.total_gear_count = summary.total_gear_count + (item.count or 0)
                    table.insert(summary.gear, {
                        name = tostring(item.name or ""),
                        category = tostring(item.category or ""),
                        rarity = tostring(item.rarity or "Unknown"),
                        count = item.count or 0,
                    })
                end
            end
        end

        return summary
    end

    -- Get current sheckles (in-game currency)
    Inventory.GetSheckles = function()
        if type(Z.DataReplica) ~= "table" or type(Z.DataReplica.GetData) ~= "function" then
            return 0
        end
        local ok, val = pcall(function()
            return Z.DataReplica.GetData("Shekels") or Z.DataReplica.GetData("Currency") or 0
        end)
        return ok and (tonumber(val) or 0) or 0
    end

    -- ============================================
    -- SECTION 6: FLEET DATA MANAGEMENT
    -- ============================================

    local FleetData = {}

    -- Generate a random fleet code
    FleetData.GenerateFleetCode = function()
        local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        local code = ""
        for i = 1, 8 do
            local idx = math.random(1, #chars)
            code = code .. chars:sub(idx, idx)
        end
        return code
    end

    -- Build account entry for this account
    FleetData.BuildAccountEntry = function()
        local invSummary = Inventory.CollectInventorySummary()
        return {
            username = tostring(y.LocalPlayer and y.LocalPlayer.Name or ""),
            user_id = tostring(g.player_userid or ""),
            role = Fleet.Role,
            last_seen = os.time(),
            status = "online",
            place_id = tostring(game.PlaceId or ""),
            job_id = tostring(game.JobId or ""),
            sheckles = Inventory.GetSheckles(),
            version = tostring(y.CurentV or ""),
            inventory_summary = invSummary,
        }
    end

    -- Initialize fleet data structure
    FleetData.CreateInitialData = function()
        return {
            fleet_code = Fleet.FleetCode,
            controller_id = Fleet.Role == "controller" and tostring(g.player_userid) or "",
            created_at = os.time(),
            last_updated = os.time(),
            accounts = {},
            commands = {},
            send_log = {},
        }
    end

    -- Set status
    FleetData.SetStatus = function(text, color)
        text = tostring(text or "")
        color = tostring(color or "#FFFFFF")
        if text == "" then
            Fleet.StatusText = ""
        else
            Fleet.StatusText = string.format(
                "<stroke color='#000000' thickness='1'><font color='#FFFFFF'>🔗 [Fleet]</font> <font color='%s'>%s</font></stroke>",
                color, text
            )
        end
        -- Update UI label if exists
        if Fleet.UiRefs.StatusLabel and type(Fleet.UiRefs.StatusLabel.SetText) == "function" then
            Fleet.UiRefs.StatusLabel:SetText(
                text ~= "" and string.format("<font color='%s'>%s</font>", color, text)
                or "<font color='#888888'>Not connected</font>"
            )
        end
    end

    -- Connect to fleet (create or join)
    FleetData.Connect = function()
        if Fleet.MasterKey == "" then
            FleetData.SetStatus("Enter JSONBin API Key", "#FF6666")
            return false, "No API key"
        end
        if Fleet.FleetCode == "" then
            FleetData.SetStatus("Enter or generate Fleet Code", "#FF6666")
            return false, "No fleet code"
        end

        FleetData.SetStatus("Connecting...", "#FFCC66")

        -- If we have a bin ID, try to read it
        if Fleet.BinId ~= "" then
            local data, err = JsonBin.ReadBin(Fleet.BinId)
            if data and type(data) == "table" and data.fleet_code == Fleet.FleetCode then
                Fleet.Data = data
                Fleet.Connected = true
                -- Register this account
                FleetData.RegisterAccount()
                FleetData.SetStatus("Connected ✓", "#7CFC00")
                return true
            end
            -- Bin ID invalid, clear it
            Fleet.BinId = ""
        end

        -- Try to create a new bin
        local initialData = FleetData.CreateInitialData()
        local binId, err = JsonBin.CreateBin(initialData)
        if not binId then
            FleetData.SetStatus(tostring(err or "Connection failed"), "#FF6666")
            return false, err
        end

        Fleet.BinId = binId
        Fleet.Data = initialData
        Fleet.Connected = true

        -- Save bin ID
        X.fleet_bin_id = binId
        if a and a.Save then a.Save.SaveData() end

        -- Register this account
        FleetData.RegisterAccount()
        FleetData.SetStatus("Created fleet & connected ✓", "#7CFC00")
        return true
    end

    -- Register current account in fleet
    FleetData.RegisterAccount = function()
        if not Fleet.Connected or not Fleet.Data then return false end

        local userId = tostring(g.player_userid or "")
        if userId == "" then return false end

        if type(Fleet.Data.accounts) ~= "table" then
            Fleet.Data.accounts = {}
        end

        Fleet.Data.accounts[userId] = FleetData.BuildAccountEntry()
        Fleet.Data.last_updated = os.time()

        if Fleet.Role == "controller" then
            Fleet.Data.controller_id = userId
        end

        -- Push to JSONBin
        local ok, err = JsonBin.UpdateBin(Fleet.BinId, Fleet.Data)
        if not ok then
            FleetData.SetStatus("Sync failed: " .. tostring(err), "#FF6666")
            return false
        end

        Fleet.LastSync = os.time()
        return true
    end

    -- Sync: Pull latest data from JSONBin
    FleetData.Pull = function()
        if not Fleet.Connected or Fleet.BinId == "" then return false end

        local data, err = JsonBin.ReadBin(Fleet.BinId)
        if not data then
            FleetData.SetStatus("Pull failed", "#FF6666")
            return false
        end

        Fleet.Data = data
        Fleet.LastSync = os.time()
        return true
    end

    -- Heartbeat: Update this account's status + inventory
    FleetData.Heartbeat = function()
        if not Fleet.Connected or not Fleet.Data then return false end

        -- Pull latest first
        FleetData.Pull()

        -- Update our entry
        local userId = tostring(g.player_userid or "")
        if userId == "" then return false end

        if type(Fleet.Data.accounts) ~= "table" then
            Fleet.Data.accounts = {}
        end

        Fleet.Data.accounts[userId] = FleetData.BuildAccountEntry()
        Fleet.Data.last_updated = os.time()

        -- Push
        local ok = JsonBin.UpdateBin(Fleet.BinId, Fleet.Data)
        Fleet.LastHeartbeat = os.time()
        return ok
    end

    -- Mark account offline
    FleetData.MarkOffline = function()
        if not Fleet.Connected or not Fleet.Data then return false end

        local userId = tostring(g.player_userid or "")
        if Fleet.Data.accounts and Fleet.Data.accounts[userId] then
            Fleet.Data.accounts[userId].status = "offline"
            Fleet.Data.accounts[userId].last_seen = os.time()
            JsonBin.UpdateBin(Fleet.BinId, Fleet.Data)
        end
    end

    -- ============================================
    -- SECTION 7: COMMAND SYSTEM
    -- ============================================

    local Commands = {}

    -- Send command to a specific worker
    Commands.SendCommand = function(targetUserId, command)
        if not Fleet.Connected or not Fleet.Data then
            return false, "Not connected"
        end

        -- Pull latest
        FleetData.Pull()

        if type(Fleet.Data.commands) ~= "table" then
            Fleet.Data.commands = {}
        end

        command.issued_at = os.time()
        command.issued_by = tostring(g.player_userid or "")
        command.status = "pending"

        Fleet.Data.commands[targetUserId] = command
        Fleet.Data.last_updated = os.time()

        local ok = JsonBin.UpdateBin(Fleet.BinId, Fleet.Data)
        if ok then
            FleetData.SetStatus("Command sent to " .. tostring(targetUserId), "#7CFC00")
        end
        return ok
    end

    -- Send command to all workers
    Commands.SendToAllWorkers = function(command)
        if not Fleet.Connected or not Fleet.Data then return false end

        FleetData.Pull()

        local sent = 0
        local myId = tostring(g.player_userid or "")

        if type(Fleet.Data.accounts) ~= "table" then return false end
        if type(Fleet.Data.commands) ~= "table" then
            Fleet.Data.commands = {}
        end

        for userId, acc in pairs(Fleet.Data.accounts) do
            if userId ~= myId and acc.role == "worker" and acc.status == "online" then
                local cmd = {}
                for k, v in pairs(command) do cmd[k] = v end
                cmd.issued_at = os.time()
                cmd.issued_by = myId
                cmd.status = "pending"
                Fleet.Data.commands[userId] = cmd
                sent = sent + 1
            end
        end

        if sent > 0 then
            Fleet.Data.last_updated = os.time()
            JsonBin.UpdateBin(Fleet.BinId, Fleet.Data)
            FleetData.SetStatus("Commands sent to " .. sent .. " workers", "#7CFC00")
        end
        return sent > 0
    end

    -- Check for pending commands (for workers)
    Commands.CheckPendingCommand = function()
        if not Fleet.Connected or Fleet.Role ~= "worker" then return nil end

        FleetData.Pull()

        local myId = tostring(g.player_userid or "")
        if type(Fleet.Data.commands) ~= "table" then return nil end

        local cmd = Fleet.Data.commands[myId]
        if type(cmd) ~= "table" or cmd.status ~= "pending" then return nil end

        return cmd
    end

    -- Mark command as completed
    Commands.MarkCommandDone = function(status, result)
        if not Fleet.Connected or not Fleet.Data then return false end

        local myId = tostring(g.player_userid or "")
        if type(Fleet.Data.commands) ~= "table" then return false end

        if Fleet.Data.commands[myId] then
            Fleet.Data.commands[myId].status = status or "completed"
            Fleet.Data.commands[myId].result = result or ""
            Fleet.Data.commands[myId].completed_at = os.time()
            Fleet.Data.last_updated = os.time()
            JsonBin.UpdateBin(Fleet.BinId, Fleet.Data)
        end
        return true
    end

    -- Log a send action
    Commands.LogSend = function(fromId, toId, itemName, category, value, weight, status)
        local entry = {
            from = tostring(fromId),
            to = tostring(toId),
            item = tostring(itemName),
            category = tostring(category),
            value = tonumber(value) or 0,
            weight = tonumber(weight) or 0,
            at = os.time(),
            status = tostring(status or "success"),
        }

        -- Local log
        table.insert(Fleet.SendLog, 1, entry)
        if #Fleet.SendLog > 100 then
            table.remove(Fleet.SendLog, #Fleet.SendLog)
        end

        -- Remote log
        if Fleet.Connected and Fleet.Data then
            if type(Fleet.Data.send_log) ~= "table" then
                Fleet.Data.send_log = {}
            end
            table.insert(Fleet.Data.send_log, 1, entry)
            -- Keep only last 200 entries
            while #Fleet.Data.send_log > 200 do
                table.remove(Fleet.Data.send_log, #Fleet.Data.send_log)
            end
        end

        Fleet.TotalSentValue = Fleet.TotalSentValue + (tonumber(value) or 0)
    end

    -- ============================================
    -- SECTION 8: SEND EXECUTOR
    -- ============================================

    local Sender = {}

    -- Get the target player object in the current server
    Sender.GetTargetPlayer = function(targetUserId)
        targetUserId = tostring(targetUserId or "")
        if targetUserId == "" then return nil end

        for _, player in ipairs(y.Players:GetPlayers()) do
            if tostring(player.UserId) == targetUserId or player.Name == targetUserId then
                return player
            end
        end
        return nil
    end

    -- Check if a fruit passes the send filters
    Sender.PassesFilters = function(fruitData, filters)
        if type(fruitData) ~= "table" or type(filters) ~= "table" then
            return false
        end

        local name = tostring(fruitData.name or fruitData.n or "")
        if name == "" then return false end

        -- Fruit name filter
        if type(filters.fruit_names) == "table" and next(filters.fruit_names) then
            local found = false
            for _, fn in pairs(filters.fruit_names) do
                if tostring(fn) == name then found = true; break end
            end
            if not found then return false end
        end

        -- Weight range
        local weight = tonumber(fruitData.w or fruitData.weight) or 0
        local minW = tonumber(filters.min_weight) or 0
        local maxW = tonumber(filters.max_weight) or 999999
        if weight < minW or weight > maxW then return false end

        -- Protect favourites
        if filters.protect_favourites ~= false then
            if type(Z.GiftSystem) == "table" and type(Z.GiftSystem.IsFavouriteFruitGiftSystem) == "function" then
                if Z.GiftSystem.IsFavouriteFruitGiftSystem(fruitData) then
                    return false
                end
            end
        end

        return true
    end

    -- Execute send command: send fruits/items to target
    Sender.ExecuteSendCommand = function(command)
        if type(command) ~= "table" then return false, "Invalid command" end
        if Fleet.SenderBusy then return false, "Already sending" end

        local targetId = tostring(command.target_id or "")
        local targetPlayer = Sender.GetTargetPlayer(targetId)
        if not targetPlayer then
            return false, "Target player not in server"
        end

        local filters = type(command.filters) == "table" and command.filters or {}
        local categories = type(filters.categories) == "table" and filters.categories or {"HarvestedFruits"}
        local maxValue = math.max(tonumber(filters.max_total_value) or 0, 0)
        local maxItems = math.max(math.floor(tonumber(filters.max_items) or 0), 0)
        local keepAmount = math.max(math.floor(tonumber(filters.keep_amount) or 0), 0)
        local previewOnly = X.fleet_send_preview_only ~= false
        local delay = math.clamp(tonumber(X.fleet_send_delay) or 1.25, 0.35, 30)

        Fleet.SenderBusy = true
        FleetData.SetStatus("Sending items...", "#FFCC66")

        local sentCount = 0
        local sentValue = 0
        local myId = tostring(g.player_userid or "")

        -- Process HarvestedFruits
        local hasFruits = false
        for _, cat in ipairs(categories) do
            if cat == "HarvestedFruits" then hasFruits = true; break end
        end

        if hasFruits and type(Z.GiftSystem) == "table" then
            -- Get filtered fruits
            local fruits = {}
            if type(Z.GiftSystem.GetBackpackFruitsGiftSystem) == "function" then
                local allFruits = Z.GiftSystem.GetBackpackFruitsGiftSystem()
                local fruitCounts = Z.GiftSystem.GetFruitCountsGiftSystem(allFruits)
                local usedCounts = {}

                for _, fruit in ipairs(allFruits) do
                    if Sender.PassesFilters(fruit, filters) then
                        local fname = tostring(fruit.name or fruit.n or "")
                        local total = fruitCounts[fname] or 0
                        local used = usedCounts[fname] or 0

                        if keepAmount > 0 and used >= math.max(total - keepAmount, 0) then
                            -- Skip: keeping enough
                        else
                            usedCounts[fname] = used + 1
                            table.insert(fruits, fruit)
                        end
                    end
                end
            end

            -- Sort by lowest weight first
            table.sort(fruits, function(a, b)
                return (tonumber(a.w) or 0) < (tonumber(b.w) or 0)
            end)

            -- Send each fruit
            for _, fruit in ipairs(fruits) do
                -- Check limits
                if maxItems > 0 and sentCount >= maxItems then break end
                if maxValue > 0 and sentValue >= maxValue then break end
                if g.is_forced_stop then break end

                local name = tostring(fruit.name or fruit.n or "")
                local weight = tonumber(fruit.w or fruit.weight) or 0
                local price = Pricing.GetFruitPrice(name, fruit, tostring(fruit.m or fruit.mutation or ""))

                -- Check value cap
                if maxValue > 0 and sentValue + price > maxValue then
                    break
                end

                FleetData.SetStatus(string.format("Sending %s (%.1fkg) 💰%s...", name, weight, Pricing.FormatPrice(price)), "#FFCC66")

                if previewOnly then
                    -- Preview: just log
                    Commands.LogSend(myId, targetId, name, "HarvestedFruits", price, weight, "preview")
                    sentCount = sentCount + 1
                    sentValue = sentValue + price
                else
                    -- Actual send using existing gift system
                    local ok, result = pcall(function()
                        return Z.GiftSystem.SendFruitGiftSystem(targetPlayer, fruit)
                    end)
                    if ok and result then
                        Commands.LogSend(myId, targetId, name, "HarvestedFruits", price, weight, "success")
                        sentCount = sentCount + 1
                        sentValue = sentValue + price
                    else
                        Commands.LogSend(myId, targetId, name, "HarvestedFruits", price, weight, "failed")
                    end
                end

                task.wait(delay)
            end
        end

        Fleet.SenderBusy = false

        local modeText = previewOnly and " (PREVIEW)" or ""
        FleetData.SetStatus(
            string.format("Done%s: %d items, 💰%s total", modeText, sentCount, Pricing.FormatPrice(sentValue)),
            "#7CFC00"
        )

        -- Update command status
        Commands.MarkCommandDone("completed", string.format("%d items, %s value", sentCount, Pricing.FormatPrice(sentValue)))

        -- Sync to JSONBin
        FleetData.Heartbeat()

        return true, sentCount, sentValue
    end

    -- ============================================
    -- SECTION 9: FLEET VIEW (for controller)
    -- ============================================

    local FleetView = {}

    -- Get all connected accounts info
    FleetView.GetAccountsSummary = function()
        if not Fleet.Data or type(Fleet.Data.accounts) ~= "table" then
            return {}, 0, 0
        end

        local accounts = {}
        local totalValue = 0
        local onlineCount = 0

        for userId, acc in pairs(Fleet.Data.accounts) do
            local isOnline = acc.status == "online" and (os.time() - (acc.last_seen or 0)) < 120
            if isOnline then onlineCount = onlineCount + 1 end

            local inv = type(acc.inventory_summary) == "table" and acc.inventory_summary or {}
            local fruitValue = tonumber(inv.total_fruit_value) or 0
            totalValue = totalValue + fruitValue

            table.insert(accounts, {
                user_id = userId,
                username = tostring(acc.username or ""),
                role = tostring(acc.role or "worker"),
                is_online = isOnline,
                last_seen = acc.last_seen or 0,
                sheckles = tonumber(acc.sheckles) or 0,
                fruit_value = fruitValue,
                fruit_count = tonumber(inv.total_fruit_count) or 0,
                pet_count = tonumber(inv.total_pet_count) or 0,
                seed_count = tonumber(inv.total_seed_count) or 0,
                fruits = inv.fruits or {},
                pets = inv.pets or {},
                seeds = inv.seeds or {},
                gear = inv.gear or {},
                job_id = tostring(acc.job_id or ""),
            })
        end

        table.sort(accounts, function(a, b)
            if a.role ~= b.role then return a.role == "controller" end
            if a.is_online ~= b.is_online then return a.is_online end
            return a.fruit_value > b.fruit_value
        end)

        return accounts, totalValue, onlineCount
    end

    -- Get fleet totals
    FleetView.GetFleetTotals = function()
        local accounts, totalValue, onlineCount = FleetView.GetAccountsSummary()
        local totals = {
            account_count = #accounts,
            online_count = onlineCount,
            total_fruit_value = totalValue,
            total_fruits = 0,
            total_pets = 0,
            total_seeds = 0,
        }
        for _, acc in ipairs(accounts) do
            totals.total_fruits = totals.total_fruits + acc.fruit_count
            totals.total_pets = totals.total_pets + acc.pet_count
            totals.total_seeds = totals.total_seeds + acc.seed_count
        end
        return totals
    end

    -- Get send log
    FleetView.GetSendLog = function(limit)
        limit = math.min(tonumber(limit) or 20, 100)
        local log = Fleet.Data and Fleet.Data.send_log or Fleet.SendLog
        local result = {}
        for i = 1, math.min(#log, limit) do
            table.insert(result, log[i])
        end
        return result
    end

    -- ============================================
    -- SECTION 10: UI BUILDER
    -- ============================================

    local UI = {}

    UI.BuildFleetTab = function()
        if u or not d then return false end

        local FleetTab = d:AddTab({
            Name = "<font color=\"#FFFFFF\">Fleet </font><font color=\"#FFD700\">Manager</font>",
            Description = "<font color=\"#B4B4B4\">Multi-Account Control Panel</font>",
            Icon = "network",
        })
        if not FleetTab then return false end

        -- ===== Connection Groupbox =====
        local connBox = FleetTab:AddLeftGroupbox("🔗 Fleet Connection", "link")
        if connBox then
            connBox:AddLabel({
                Text = "📡 Connect multiple accounts via JSONBin.io relay. Get free API key at jsonbin.io",
                DoesWrap = true,
            })

            connBox:AddInput("fleet_jsonbin_key_ui", {
                Text = "🔑 JSONBin API Key",
                Default = X.fleet_jsonbin_key or "",
                Placeholder = "Paste your $2a$10$... key",
                Finished = true,
                Callback = function(val)
                    X.fleet_jsonbin_key = tostring(val or "")
                    Fleet.MasterKey = X.fleet_jsonbin_key
                    if a and a.Save then a.Save.SaveData() end
                end,
            })

            connBox:AddInput("fleet_code_ui", {
                Text = "🏷️ Fleet Code",
                Default = X.fleet_code or "",
                Placeholder = "Enter or generate code",
                Finished = true,
                Callback = function(val)
                    X.fleet_code = tostring(val or "")
                    Fleet.FleetCode = X.fleet_code
                    if a and a.Save then a.Save.SaveData() end
                end,
            })

            connBox:AddButton({
                Text = "🎲 Generate Code",
                Func = function()
                    local code = FleetData.GenerateFleetCode()
                    X.fleet_code = code
                    Fleet.FleetCode = code
                    if a and a.Save then a.Save.SaveData() end
                    g.Notify("Fleet code generated: " .. code, 3)
                end,
            })

            connBox:AddInput("fleet_bin_id_ui", {
                Text = "📦 Bin ID (auto-filled)",
                Default = X.fleet_bin_id or "",
                Placeholder = "Auto-created on connect",
                Finished = true,
                Callback = function(val)
                    X.fleet_bin_id = tostring(val or "")
                    Fleet.BinId = X.fleet_bin_id
                    if a and a.Save then a.Save.SaveData() end
                end,
            })

            connBox:AddDropdown("fleet_role_ui", {
                Values = {"controller", "worker"},
                Default = X.fleet_role or "worker",
                Text = "👤 Account Role",
                Callback = function(val)
                    X.fleet_role = tostring(val or "worker")
                    Fleet.Role = X.fleet_role
                    if a and a.Save then a.Save.SaveData() end
                end,
            })

            connBox:AddButton({
                Text = "🔌 Connect to Fleet",
                Func = function()
                    Fleet.MasterKey = X.fleet_jsonbin_key or ""
                    Fleet.FleetCode = X.fleet_code or ""
                    Fleet.BinId = X.fleet_bin_id or ""
                    Fleet.Role = X.fleet_role or "worker"

                    task.spawn(function()
                        local ok, err = FleetData.Connect()
                        if ok then
                            g.Notify("✅ Fleet connected!", 3)
                            UI.RefreshAccountsList()
                        else
                            g.Notify("❌ Connection failed: " .. tostring(err), 4)
                        end
                    end)
                end,
            })

            connBox:AddButton({
                Text = "🔄 Refresh Data",
                Func = function()
                    task.spawn(function()
                        FleetData.Heartbeat()
                        UI.RefreshAccountsList()
                        g.Notify("Fleet data refreshed", 2)
                    end)
                end,
            })

            Fleet.UiRefs.StatusLabel = connBox:AddLabel({
                Text = "<font color='#888888'>Not connected</font>",
                DoesWrap = true,
            })

            connBox:AddToggle("fleet_enabled_ui", {
                Text = "⚡ Enable Fleet System",
                Default = X.fleet_enabled or false,
                Callback = function(val)
                    X.fleet_enabled = val
                    if a and a.Save then a.Save.SaveData() end
                end,
            })
        end

        -- ===== Accounts Overview Groupbox =====
        local accBox = FleetTab:AddRightGroupbox("👥 Connected Accounts", "users")
        if accBox then
            Fleet.UiRefs.AccountsLabel = accBox:AddLabel({
                Text = "<font color='#888888'>Connect to see accounts</font>",
                DoesWrap = true,
            })

            Fleet.UiRefs.TotalsLabel = accBox:AddLabel({
                Text = "",
                DoesWrap = true,
            })

            accBox:AddButton({
                Text = "📊 View Detailed Inventory",
                Func = function()
                    task.spawn(function()
                        UI.ShowDetailedInventory()
                    end)
                end,
            })
        end

        -- ===== Send Settings Groupbox =====
        local sendBox = FleetTab:AddLeftGroupbox("📦 Send Settings", "send")
        if sendBox then
            sendBox:AddLabel({
                Text = "🚀 Configure what to send from worker accounts to the controller. Keep Preview Only ON until ready.",
                DoesWrap = true,
            })

            sendBox:AddToggle("fleet_send_preview_ui", {
                Text = "👁️ Preview Only (no actual send)",
                Default = X.fleet_send_preview_only ~= false,
                Callback = function(val)
                    X.fleet_send_preview_only = val
                    if a and a.Save then a.Save.SaveData() end
                end,
            })

            -- Category selection
            local catValues = {
                "HarvestedFruits", "Seeds", "Pets", "Sprinklers",
                "WateringCans", "Mushrooms", "Gnomes", "Crates",
            }
            sendBox:AddDropdown("fleet_send_categories_ui", {
                Values = catValues,
                Default = X.fleet_send_categories or {},
                Multi = true,
                Text = "📂 Categories to Send",
                Callback = function(val)
                    X.fleet_send_categories = val
                    if a and a.Save then a.Save.SaveData() end
                end,
            })

            -- Fruit name filter
            local fruitNames = {}
            if type(Z.SeedData) == "table" and type(Z.SeedData.GetSeedDataListDropDown) == "function" then
                local ok, names = pcall(Z.SeedData.GetSeedDataListDropDown)
                if ok then fruitNames = names end
            end
            sendBox:AddDropdown("fleet_send_fruits_ui", {
                Values = fruitNames,
                Default = X.fleet_send_fruit_names or {},
                Multi = true,
                Searchable = true,
                MaxVisibleDropdownItems = 10,
                Text = "🍎 Fruit Names (empty = all)",
                Callback = function(val)
                    X.fleet_send_fruit_names = val
                    if a and a.Save then a.Save.SaveData() end
                end,
            })

            sendBox:AddInput("fleet_send_min_weight_ui", {
                Text = "⚖️ Min Weight (kg)",
                Default = tostring(X.fleet_send_min_weight or 0),
                Numeric = true,
                Finished = true,
                Callback = function(val)
                    X.fleet_send_min_weight = tonumber(val) or 0
                    if a and a.Save then a.Save.SaveData() end
                end,
            })

            sendBox:AddInput("fleet_send_max_weight_ui", {
                Text = "⚖️ Max Weight (kg)",
                Default = tostring(X.fleet_send_max_weight or 100000),
                Numeric = true,
                Finished = true,
                Callback = function(val)
                    X.fleet_send_max_weight = tonumber(val) or 100000
                    if a and a.Save then a.Save.SaveData() end
                end,
            })

            sendBox:AddInput("fleet_send_max_value_ui", {
                Text = "💰 Max Total Value (0 = unlimited)",
                Default = tostring(X.fleet_send_max_total_value or 0),
                Numeric = true,
                Finished = true,
                Callback = function(val)
                    X.fleet_send_max_total_value = tonumber(val) or 0
                    if a and a.Save then a.Save.SaveData() end
                end,
            })

            sendBox:AddInput("fleet_send_max_items_ui", {
                Text = "📦 Max Items (0 = unlimited)",
                Default = tostring(X.fleet_send_max_items or 0),
                Numeric = true,
                Finished = true,
                Callback = function(val)
                    X.fleet_send_max_items = tonumber(val) or 0
                    if a and a.Save then a.Save.SaveData() end
                end,
            })

            sendBox:AddInput("fleet_send_keep_ui", {
                Text = "🛡️ Keep Per Fruit Type",
                Default = tostring(X.fleet_send_keep_amount or 0),
                Numeric = true,
                Finished = true,
                Callback = function(val)
                    X.fleet_send_keep_amount = tonumber(val) or 0
                    if a and a.Save then a.Save.SaveData() end
                end,
            })

            sendBox:AddInput("fleet_send_delay_ui", {
                Text = "⏱️ Send Delay (seconds)",
                Default = tostring(X.fleet_send_delay or 1.25),
                Numeric = true,
                Finished = true,
                Callback = function(val)
                    X.fleet_send_delay = tonumber(val) or 1.25
                    if a and a.Save then a.Save.SaveData() end
                end,
            })

            sendBox:AddToggle("fleet_send_protect_fav_ui", {
                Text = "⭐ Protect Favourites",
                Default = X.fleet_send_protect_favourites ~= false,
                Callback = function(val)
                    X.fleet_send_protect_favourites = val
                    if a and a.Save then a.Save.SaveData() end
                end,
            })
        end

        -- ===== Send Actions Groupbox =====
        local actBox = FleetTab:AddRightGroupbox("🚀 Send Actions", "zap")
        if actBox then
            actBox:AddButton({
                Text = "📤 Send From THIS Account",
                Func = function()
                    task.spawn(function()
                        local controllerId = Fleet.Data and Fleet.Data.controller_id or ""
                        if controllerId == "" then
                            g.Notify("❌ No controller set", 3)
                            return
                        end
                        local cmd = {
                            action = "send_to_controller",
                            target_id = controllerId,
                            filters = {
                                categories = X.fleet_send_categories or {"HarvestedFruits"},
                                fruit_names = X.fleet_send_fruit_names or {},
                                min_weight = X.fleet_send_min_weight or 0,
                                max_weight = X.fleet_send_max_weight or 100000,
                                max_total_value = X.fleet_send_max_total_value or 0,
                                max_items = X.fleet_send_max_items or 0,
                                keep_amount = X.fleet_send_keep_amount or 0,
                                protect_favourites = X.fleet_send_protect_favourites ~= false,
                            },
                        }
                        Sender.ExecuteSendCommand(cmd)
                        UI.RefreshAccountsList()
                    end)
                end,
            })

            actBox:AddButton({
                Text = "📤 Send From ALL Workers (Command)",
                Func = function()
                    task.spawn(function()
                        local controllerId = Fleet.Data and Fleet.Data.controller_id or ""
                        if controllerId == "" then
                            g.Notify("❌ No controller set", 3)
                            return
                        end
                        local cmd = {
                            action = "send_to_controller",
                            target_id = controllerId,
                            filters = {
                                categories = X.fleet_send_categories or {"HarvestedFruits"},
                                fruit_names = X.fleet_send_fruit_names or {},
                                min_weight = X.fleet_send_min_weight or 0,
                                max_weight = X.fleet_send_max_weight or 100000,
                                max_total_value = X.fleet_send_max_total_value or 0,
                                max_items = X.fleet_send_max_items or 0,
                                keep_amount = X.fleet_send_keep_amount or 0,
                                protect_favourites = X.fleet_send_protect_favourites ~= false,
                            },
                        }
                        Commands.SendToAllWorkers(cmd)
                        g.Notify("📤 Command sent to all workers!", 3)
                    end)
                end,
            })

            actBox:AddButton({
                Text = "🛑 Stop Sending",
                Func = function()
                    Fleet.SenderBusy = false
                    FleetData.SetStatus("Sending stopped", "#FF6666")
                end,
            })

            -- Send log
            Fleet.UiRefs.SendLogLabel = actBox:AddLabel({
                Text = "<font color='#888888'>No sends yet</font>",
                DoesWrap = true,
            })

            Fleet.UiRefs.TotalSentLabel = actBox:AddLabel({
                Text = "",
                DoesWrap = true,
            })

            actBox:AddToggle("fleet_auto_execute_ui", {
                Text = "🤖 Auto-Execute Commands (Workers)",
                Default = X.fleet_auto_execute or false,
                Callback = function(val)
                    X.fleet_auto_execute = val
                    if a and a.Save then a.Save.SaveData() end
                end,
            })
        end

        return FleetTab
    end

    -- Refresh the accounts list in the UI
    UI.RefreshAccountsList = function()
        if not Fleet.UiRefs.AccountsLabel then return end

        local accounts, totalValue, onlineCount = FleetView.GetAccountsSummary()

        if #accounts == 0 then
            Fleet.UiRefs.AccountsLabel:SetText("<font color='#888888'>No accounts connected</font>")
            if Fleet.UiRefs.TotalsLabel then
                Fleet.UiRefs.TotalsLabel:SetText("")
            end
            return
        end

        -- Build accounts text
        local lines = {}
        for _, acc in ipairs(accounts) do
            local statusIcon = acc.is_online and "🟢" or "🔴"
            local roleIcon = acc.role == "controller" and " 👑" or ""
            local valueText = Pricing.FormatPrice(acc.fruit_value)
            table.insert(lines, string.format(
                "%s <font color='#FFFFFF'>%s</font>%s <font color='#888888'>|</font> 💰<font color='#7CFC00'>%s</font> <font color='#888888'>| 🍎%d 🐾%d 🌱%d</font>",
                statusIcon, acc.username, roleIcon, valueText, acc.fruit_count, acc.pet_count, acc.seed_count
            ))
        end
        Fleet.UiRefs.AccountsLabel:SetText(table.concat(lines, "\n"))

        -- Build totals text
        if Fleet.UiRefs.TotalsLabel then
            local totals = FleetView.GetFleetTotals()
            Fleet.UiRefs.TotalsLabel:SetText(string.format(
                "━━━━━━━━━━━━━━━━━━━━━━\n📊 <font color='#FFD700'>FLEET TOTAL: 💰%s</font>\n<font color='#AAAAAA'>%d/%d online | 🍎%d fruits | 🐾%d pets | 🌱%d seeds</font>",
                Pricing.FormatPrice(totals.total_fruit_value),
                totals.online_count, totals.account_count,
                totals.total_fruits, totals.total_pets, totals.total_seeds
            ))
        end

        -- Update send log
        UI.RefreshSendLog()
    end

    -- Refresh send log display
    UI.RefreshSendLog = function()
        if not Fleet.UiRefs.SendLogLabel then return end

        local log = FleetView.GetSendLog(10)
        if #log == 0 then
            Fleet.UiRefs.SendLogLabel:SetText("<font color='#888888'>No sends yet</font>")
        else
            local lines = {"<font color='#FFD700'>📋 Recent Sends:</font>"}
            for _, entry in ipairs(log) do
                local statusColor = entry.status == "success" and "#7CFC00" or (entry.status == "preview" and "#FFCC66" or "#FF6666")
                local statusIcon = entry.status == "success" and "✅" or (entry.status == "preview" and "👁️" or "❌")
                table.insert(lines, string.format(
                    "%s <font color='#AAAAAA'>%s → %s:</font> <font color='#FFFFFF'>%s</font> 💰<font color='%s'>%s</font>",
                    statusIcon, tostring(entry.from):sub(1, 6), tostring(entry.to):sub(1, 6),
                    entry.item, statusColor, Pricing.FormatPrice(entry.value)
                ))
            end
            Fleet.UiRefs.SendLogLabel:SetText(table.concat(lines, "\n"))
        end

        if Fleet.UiRefs.TotalSentLabel then
            Fleet.UiRefs.TotalSentLabel:SetText(string.format(
                "💰 <font color='#FFD700'>Total Sent This Session: %s</font>",
                Pricing.FormatPrice(Fleet.TotalSentValue)
            ))
        end
    end

    -- Show detailed inventory popup via notification
    UI.ShowDetailedInventory = function()
        if not Fleet.Data or type(Fleet.Data.accounts) ~= "table" then
            g.Notify("No fleet data available", 3)
            return
        end

        local accounts, totalValue = FleetView.GetAccountsSummary()
        local msg = {}

        for _, acc in ipairs(accounts) do
            table.insert(msg, string.format("═══ %s (%s) ═══", acc.username, acc.role))
            table.insert(msg, string.format("  💰 Total: %s | 🍎 %d fruits", Pricing.FormatPrice(acc.fruit_value), acc.fruit_count))

            -- Top 5 fruits
            for i, fruit in ipairs(acc.fruits) do
                if i > 5 then break end
                table.insert(msg, string.format("    %s x%d = %s (avg %.1fkg)",
                    fruit.name, fruit.count, Pricing.FormatPrice(fruit.total_value), fruit.avg_weight or 0))
            end
        end

        table.insert(msg, "═══════════════════")
        table.insert(msg, string.format("FLEET TOTAL: 💰 %s", Pricing.FormatPrice(totalValue)))

        g.Notify(table.concat(msg, "\n"), 15)
    end

    -- ============================================
    -- SECTION 11: MAIN LOOPS
    -- ============================================

    local Loops = {}

    -- Heartbeat loop (reports inventory periodically)
    Loops.StartHeartbeat = function()
        task.spawn(function()
            task.wait(5) -- Initial delay
            while not g.is_forced_stop do
                if X.fleet_enabled and Fleet.Connected then
                    local interval = math.max(tonumber(X.fleet_report_interval) or 30, 15)
                    if os.time() - Fleet.LastHeartbeat >= interval then
                        local ok, err = pcall(function()
                            FleetData.Heartbeat()
                            UI.RefreshAccountsList()
                        end)
                        if not ok then
                            warn("[Fleet Heartbeat]", err)
                        end
                    end
                end
                task.wait(5)
            end
        end)
    end

    -- Command polling loop (for workers)
    Loops.StartCommandPolling = function()
        task.spawn(function()
            task.wait(10) -- Initial delay
            while not g.is_forced_stop do
                if X.fleet_enabled and Fleet.Connected and Fleet.Role == "worker" and X.fleet_auto_execute then
                    if os.time() - Fleet.LastCommandCheck >= 10 then
                        Fleet.LastCommandCheck = os.time()
                        local cmd = Commands.CheckPendingCommand()
                        if cmd and cmd.action == "send_to_controller" then
                            FleetData.SetStatus("Received send command, executing...", "#FFCC66")
                            local ok, err = pcall(function()
                                Sender.ExecuteSendCommand(cmd)
                            end)
                            if not ok then
                                Commands.MarkCommandDone("error", tostring(err))
                                FleetData.SetStatus("Command error: " .. tostring(err), "#FF6666")
                            end
                        end
                    end
                end
                task.wait(5)
            end
        end)
    end

    -- Auto-connect on startup
    Loops.AutoConnect = function()
        task.spawn(function()
            task.wait(8) -- Wait for game to load
            if X.fleet_enabled and (X.fleet_jsonbin_key or "") ~= "" and (X.fleet_code or "") ~= "" then
                Fleet.MasterKey = X.fleet_jsonbin_key
                Fleet.FleetCode = X.fleet_code
                Fleet.BinId = X.fleet_bin_id or ""
                Fleet.Role = X.fleet_role or "worker"

                local ok = FleetData.Connect()
                if ok then
                    UI.RefreshAccountsList()
                end
            end
        end)
    end

    -- ============================================
    -- SECTION 12: PUBLIC API
    -- ============================================

    -- Build the UI tab
    FleetManager.BuildUI = function()
        return UI.BuildFleetTab()
    end

    -- Start all fleet systems
    FleetManager.Start = function()
        Loops.AutoConnect()
        Loops.StartHeartbeat()
        Loops.StartCommandPolling()

        -- Register cleanup on unload
        if T and type(T.UnloadSignals) == "table" then
            table.insert(T.UnloadSignals, {
                Disconnect = function()
                    FleetData.MarkOffline()
                end
            })
        end
    end

    -- Get fleet state for external access
    FleetManager.GetState = function()
        return Fleet
    end

    -- Get fleet view functions
    FleetManager.GetView = function()
        return FleetView
    end

    -- Get pricing functions
    FleetManager.GetPricing = function()
        return Pricing
    end

    -- Get status text for watermark
    FleetManager.GetStatusText = function()
        return Fleet.StatusText
    end

    return FleetManager
end

return FleetManager
