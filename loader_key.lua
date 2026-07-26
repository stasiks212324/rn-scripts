--==========================================================
--  LOADER + WORK.INK KEY SYSTEM
--  1) проверка плейса  2) проверка ключа  3) запуск скрипта
--==========================================================

local CONFIG = {
    NAME       = "Район насилия",
    SCRIPT_URL = "https://raw.githubusercontent.com/stasiks212324/rn-scripts/main/zinka",

    -- Обход CDN-кэша (нужно для raw.githubusercontent.com, там кэш ~5 мин).
    -- Выключи, если хостишь там, где лишний параметр в URL ломает отдачу.
    BUST_CACHE = true,

    -- ССЫЛКА, которую получит юзер (destination = https://work.ink/token)
    KEY_LINK   = "https://work.ink/XXXX/твоя-ссылка",

    -- ID твоего work.ink АККАУНТА. Главная защита: чужие токены имеют другой userId.
    OWNER_USER_ID = 579838,

    -- ID конкретной ссылки (необязательно). Если задать — примутся только ключи,
    -- выданные по этой ссылке. Ключи, созданные вручную, имеют linkId = nil,
    -- поэтому при заданном LINK_ID они работать не будут.
    LINK_ID    = nil,

    -- PlaceId = название игры
    ALLOWED_PLACES = {
        [93978595733734] = "[Лечение] Район насилия",
    },

    KICK_ON_WRONG_PLACE = true,
    KEY_FILE            = "rayon_key.txt",
}

--== защита от двойного запуска ==--
if getgenv().__RN_LOADER_RUNNING then
    return warn("[" .. CONFIG.NAME .. "] Скрипт уже запущен.")
end
getgenv().__RN_LOADER_RUNNING = true

--== сервисы ==--
local Players     = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TweenService= game:GetService("TweenService")
local StarterGui  = game:GetService("StarterGui")
local lp          = Players.LocalPlayer or Players.PlayerAdded:Wait()

--== утилиты ==--
local function notify(text, dur)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = CONFIG.NAME, Text = text, Duration = dur or 5,
        })
    end)
end

local function stop(reason, kick)
    getgenv().__RN_LOADER_RUNNING = nil
    warn(("[%s] %s"):format(CONFIG.NAME, reason))
    if kick then
        task.delay(0.4, function()
            pcall(function() lp:Kick(("[%s]\n\n%s"):format(CONFIG.NAME, reason)) end)
        end)
    else
        notify(reason, 8)
    end
    error(reason, 0)
end

local function httpGet(url)
    local tries = {
        function() return game:HttpGet(url, true) end,
        function() return game:HttpGetAsync(url, true) end,
        function()
            local req = (syn and syn.request) or http_request or request
            return req and req({ Url = url, Method = "GET" }).Body
        end,
    }
    for _, fn in ipairs(tries) do
        local ok, res = pcall(fn)
        if ok and type(res) == "string" and #res > 0 then return res end
    end
    return nil
end

-- совместимость файловой системы
local hasFS = (readfile and writefile and isfile) ~= nil
local function loadSavedKey()
    if not hasFS then return nil end
    local ok, data = pcall(function()
        if isfile(CONFIG.KEY_FILE) then return readfile(CONFIG.KEY_FILE) end
    end)
    return ok and data or nil
end
local function saveKey(key)
    if hasFS then pcall(writefile, CONFIG.KEY_FILE, key) end
end
local function clearKey()
    if hasFS then pcall(function() if isfile(CONFIG.KEY_FILE) then delfile(CONFIG.KEY_FILE) end end) end
end

--==========================================================
--  ПРОВЕРКА ПЛЕЙСА
--==========================================================
if not game:IsLoaded() then game.Loaded:Wait() end

local placeName = CONFIG.ALLOWED_PLACES[game.PlaceId]
if not placeName then
    local list = {}
    for id, name in pairs(CONFIG.ALLOWED_PLACES) do
        table.insert(list, ("  - %s (%d)"):format(name, id))
    end
    stop(("Скрипт не предназначен для этой игры.\n\nТекущий PlaceId: %d\n\nПоддерживаемые игры:\n%s")
        :format(game.PlaceId, table.concat(list, "\n")), CONFIG.KICK_ON_WRONG_PLACE)
end

--==========================================================
--  ВАЛИДАЦИЯ КЛЮЧА ЧЕРЕЗ WORK.INK
--==========================================================
-- returns: ok(bool), message(string), info(table|nil)
local function validateKey(key)
    key = tostring(key or ""):gsub("%s+", "")
    if #key < 10 then return false, "Ключ слишком короткий" end
    if key:find("[^%w%-]") then return false, "В ключе недопустимые символы" end

    local body = httpGet("https://work.ink/_api/v2/token/isValid/" .. key)
    if not body then return false, "Нет связи с work.ink" end

    local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
    if not ok or type(data) ~= "table" then return false, "Некорректный ответ сервера" end

    if not data.valid then return false, "Ключ недействителен или просрочен" end

    local info = data.info or {}

    -- ГЛАВНАЯ ПРОВЕРКА: токен должен принадлежать твоему аккаунту.
    -- Эндпоинт isValid публичный, поэтому без этого подойдёт ЛЮБОЙ чужой work.ink токен.
    if CONFIG.OWNER_USER_ID and info.userId ~= CONFIG.OWNER_USER_ID then
        return false, "Ключ выдан не для этого скрипта"
    end

    -- Необязательное сужение до конкретной ссылки.
    if CONFIG.LINK_ID and info.linkId ~= CONFIG.LINK_ID then
        return false, "Ключ выдан для другого проекта"
    end

    -- срок действия (expiresAfter — метка времени в миллисекундах)
    if info.expiresAfter and info.expiresAfter > 0 then
        local leftMs = info.expiresAfter - (os.time() * 1000)
        if leftMs <= 0 then return false, "Срок действия ключа истёк" end
        return true, ("Ключ принят. Осталось: %d ч %d мин")
            :format(math.floor(leftMs / 3600000), math.floor(leftMs % 3600000 / 60000)), info
    end

    return true, "Ключ принят", info
end

--==========================================================
--  ОКНО ВВОДА КЛЮЧА
--==========================================================
local function askKey()
    local result = nil

    local parent = (gethui and gethui()) or game:GetService("CoreGui")
    local gui = Instance.new("ScreenGui")
    gui.Name = "\0KeyUI"
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.DisplayOrder = 999
    pcall(function() if syn and syn.protect_gui then syn.protect_gui(gui) end end)
    gui.Parent = parent

    local main = Instance.new("Frame", gui)
    main.Size = UDim2.fromOffset(400, 230)
    main.Position = UDim2.new(0.5, -200, 0.5, -115)
    main.BackgroundColor3 = Color3.fromRGB(22, 22, 26)
    main.BorderSizePixel = 0
    main.Active, main.Draggable = true, true
    Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)

    local stroke = Instance.new("UIStroke", main)
    stroke.Color = Color3.fromRGB(70, 70, 80)
    stroke.Thickness = 1

    local title = Instance.new("TextLabel", main)
    title.Size = UDim2.new(1, -20, 0, 40)
    title.Position = UDim2.fromOffset(15, 10)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 18
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = Color3.fromRGB(240, 240, 245)
    title.Text = CONFIG.NAME .. " — вход по ключу"

    local status = Instance.new("TextLabel", main)
    status.Size = UDim2.new(1, -30, 0, 34)
    status.Position = UDim2.fromOffset(15, 44)
    status.BackgroundTransparency = 1
    status.Font = Enum.Font.Gotham
    status.TextSize = 13
    status.TextWrapped = true
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.TextColor3 = Color3.fromRGB(150, 150, 160)
    status.Text = "Нажми «Получить ключ», пройди по ссылке и вставь ключ сюда."

    local boxBg = Instance.new("Frame", main)
    boxBg.Size = UDim2.new(1, -30, 0, 40)
    boxBg.Position = UDim2.fromOffset(15, 88)
    boxBg.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
    boxBg.BorderSizePixel = 0
    Instance.new("UICorner", boxBg).CornerRadius = UDim.new(0, 6)

    local box = Instance.new("TextBox", boxBg)
    box.Size = UDim2.new(1, -20, 1, 0)
    box.Position = UDim2.fromOffset(10, 0)
    box.BackgroundTransparency = 1
    box.Font = Enum.Font.Code
    box.TextSize = 14
    box.TextColor3 = Color3.fromRGB(235, 235, 240)
    box.PlaceholderText = "вставь ключ сюда"
    box.ClearTextOnFocus = false
    box.Text = ""

    local function mkButton(text, x, w, color)
        local b = Instance.new("TextButton", main)
        b.Size = UDim2.fromOffset(w, 38)
        b.Position = UDim2.fromOffset(x, 142)
        b.BackgroundColor3 = color
        b.BorderSizePixel = 0
        b.Font = Enum.Font.GothamMedium
        b.TextSize = 14
        b.TextColor3 = Color3.fromRGB(255, 255, 255)
        b.Text = text
        b.AutoButtonColor = true
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
        return b
    end

    local getBtn   = mkButton("Получить ключ", 15,  175, Color3.fromRGB(58, 58, 68))
    local checkBtn = mkButton("Проверить",     200, 185, Color3.fromRGB(46, 132, 74))

    local hint = Instance.new("TextLabel", main)
    hint.Size = UDim2.new(1, -30, 0, 20)
    hint.Position = UDim2.fromOffset(15, 190)
    hint.BackgroundTransparency = 1
    hint.Font = Enum.Font.Gotham
    hint.TextSize = 12
    hint.TextXAlignment = Enum.TextXAlignment.Left
    hint.TextColor3 = Color3.fromRGB(110, 110, 120)
    hint.Text = "Ссылка копируется в буфер обмена автоматически."

    local function setStatus(text, color)
        status.Text = text
        status.TextColor3 = color or Color3.fromRGB(150, 150, 160)
    end

    getBtn.MouseButton1Click:Connect(function()
        local ok = pcall(setclipboard, CONFIG.KEY_LINK)
        if ok then
            setStatus("Ссылка скопирована. Открой её в браузере, пройди шаги и вернись сюда с ключом.",
                Color3.fromRGB(120, 190, 255))
        else
            setStatus("Не удалось скопировать. Ссылка: " .. CONFIG.KEY_LINK,
                Color3.fromRGB(230, 180, 90))
        end
    end)

    local busy = false
    local function submit()
        if busy then return end
        busy = true
        checkBtn.Text = "Проверяю..."
        setStatus("Проверка ключа на сервере work.ink...", Color3.fromRGB(150, 150, 160))

        local ok, msg = validateKey(box.Text)
        if ok then
            setStatus(msg, Color3.fromRGB(120, 220, 140))
            saveKey((box.Text:gsub("%s+", "")))
            task.wait(0.8)
            gui:Destroy()
            result = true
        else
            setStatus("Ошибка: " .. msg, Color3.fromRGB(255, 110, 110))
            checkBtn.Text = "Проверить"
            busy = false
        end
    end

    checkBtn.MouseButton1Click:Connect(submit)
    box.FocusLost:Connect(function(enter) if enter then submit() end end)

    -- ждём результат
    repeat task.wait(0.1) until result ~= nil or not gui.Parent
    return result == true
end

--==========================================================
--  ЛОГИКА КЛЮЧА
--==========================================================
local granted = false

local saved = loadSavedKey()
if saved then
    local ok, msg = validateKey(saved)
    if ok then
        granted = true
        notify(msg, 5)
    else
        clearKey()
        notify("Сохранённый ключ не подошёл: " .. msg, 6)
    end
end

if not granted then
    granted = askKey()
end

if not granted then
    stop("Доступ не получен — ключ не введён.", false)
end

--==========================================================
--  ЗАГРУЗКА ОСНОВНОГО СКРИПТА
--==========================================================
notify(("Игра: %s\nЗагрузка скрипта..."):format(placeName), 4)

local scriptUrl = CONFIG.SCRIPT_URL
if CONFIG.BUST_CACHE then
    scriptUrl = scriptUrl .. (scriptUrl:find("?") and "&" or "?") .. "v=" .. tostring(os.time())
end

local source = httpGet(scriptUrl)
if not source then stop("Не удалось скачать скрипт. Проверь интернет.", false) end
if source:match("^%s*<") then stop("Сервер вернул страницу вместо кода. Проверь raw-ссылку.", false) end

local chunk, compileErr = loadstring(source, "@" .. CONFIG.NAME)
if not chunk then stop("Ошибка компиляции:\n" .. tostring(compileErr), false) end

local ranOk, runErr = pcall(chunk)
if not ranOk then stop("Ошибка выполнения:\n" .. tostring(runErr), false) end

notify("Скрипт успешно загружен", 4)
