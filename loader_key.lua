--==========================================================
--  LOADER + WORK.INK KEY SYSTEM
--  1) проверка плейса  2) проверка ключа  3) запуск скрипта
--==========================================================

local CONFIG = {
    NAME       = "Район насилия",
    -- ВРЕМЕННО: публичная raw-ссылка. Её можно открыть в браузере и списать код
    -- в обход ключа. После разворачивания воркера (worker.js) заменить на его
    -- адрес, например "https://zinka.твой-аккаунт.workers.dev"
    -- и сделать репозиторий приватным. Лоадер сам допишет ?k=КЛЮЧ.
    SCRIPT_URL = "https://raw.githubusercontent.com/stasiks212324/rn-scripts/main/zinka",

    -- Обход CDN-кэша (нужно для raw.githubusercontent.com, там кэш ~5 мин).
    -- Выключи, если хостишь там, где лишний параметр в URL ломает отдачу.
    BUST_CACHE = true,

    -- ССЫЛКА, которую получит юзер (destination = https://work.ink/token)
    KEY_LINK   = "https://work.ink/2qQe/zinka-key",

    -- ID твоего work.ink АККАУНТА. Главная защита: чужие токены имеют другой userId.
    OWNER_USER_ID = 579838,

    -- ID твоей work.ink ссылки (work.ink/2qQe/zinka-key).
    -- Ключи, полученные юзерами через рекламу, несут именно его.
    LINK_ID    = 4800430,

    -- PlaceId = название игры
    ALLOWED_PLACES = {
        [93978595733734] = "[Лечение] Район насилия",
    },

    KICK_ON_WRONG_PLACE = true,

    -- Кикать, если ключ не введён / не прошёл проверку.
    -- Сбои не по вине юзера (work.ink лежит, исходник недоступен) не кикают
    -- никогда — там он всё равно бессилен, а вылет из катки его только взбесит.
    KICK_ON_NO_KEY      = true,
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
local RunService  = game:GetService("RunService")
local UIS         = game:GetService("UserInputService")
local GuiService  = game:GetService("GuiService")
local StarterGui  = game:GetService("StarterGui")
local lp          = Players.LocalPlayer or Players.PlayerAdded:Wait()

-- Ключ, прошедший проверку. Уходит раздатчику как параметр ?k=,
-- иначе тот не отдаст исходник.
local ACCEPTED_KEY = nil

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

    -- ГЛАВНАЯ ПРОВЕРКА. Эндпоинт isValid публичный и ничем не привязан к твоему
    -- аккаунту: без этой проверки подошёл бы ЛЮБОЙ чужой work.ink токен.
    --
    -- Ключи бывают двух видов и несут РАЗНЫЕ поля:
    --   выданный по ссылке (через рекламу) -> linkId = 4800430, userId = nil
    --   созданный вручную в Manage         -> userId = 579838,  linkId = nil
    -- Поэтому принимаем, если совпало хоть одно из двух.
    local byLink  = CONFIG.LINK_ID      and info.linkId == CONFIG.LINK_ID
    local byOwner = CONFIG.OWNER_USER_ID and info.userId == CONFIG.OWNER_USER_ID
    if not (byLink or byOwner) then
        return false, "Ключ выдан не для этого скрипта"
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
--  ОКНО ВВОДА КЛЮЧА  (оформление в стиле меню ZINKA)
--==========================================================
local ACCENT = Color3.fromRGB(150, 120, 255)

local function corner(o, r)
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r); c.Parent = o; return c
end
local function stroke(o, col, th, tr)
    local s = Instance.new("UIStroke"); s.Color = col; s.Thickness = th or 1
    s.Transparency = tr or 0; s.Parent = o; return s
end
local function grad(o, seq, rot)
    local g = Instance.new("UIGradient"); g.Color = seq; g.Rotation = rot or 0; g.Parent = o; return g
end
local function tw(o, props, t, style)
    return TweenService:Create(o,
        TweenInfo.new(t, style or Enum.EasingStyle.Quart, Enum.EasingDirection.Out), props)
end

local function askKey()
    local result = nil
    local conns = {}

    local parent = (gethui and gethui()) or game:GetService("CoreGui")
    local prev = parent:FindFirstChild("ZINKA_KEY_UI")
    if prev then prev:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "ZINKA_KEY_UI"
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.DisplayOrder = 1000
    pcall(function() if syn and syn.protect_gui then syn.protect_gui(gui) end end)
    gui.Parent = parent

    local W, H = 440, 290

    --== тень (та же, что у меню ZINKA) ==--
    local shadow = Instance.new("ImageLabel")
    shadow.Name = "ZKeyShadow"; shadow.BackgroundTransparency = 1; shadow.ZIndex = 0
    shadow.Image = "rbxassetid://6015897843"
    shadow.ImageColor3 = Color3.fromRGB(0, 0, 0); shadow.ImageTransparency = 0.38
    shadow.ScaleType = Enum.ScaleType.Slice; shadow.SliceCenter = Rect.new(49, 49, 450, 450)
    shadow.AnchorPoint = Vector2.new(0.5, 0.5); shadow.Position = UDim2.fromScale(0.5, 0.5)
    shadow.Size = UDim2.fromOffset(W + 46, H + 46)
    shadow.Parent = gui

    --== корпус ==--
    local main = Instance.new("Frame")
    main.AnchorPoint = Vector2.new(0.5, 0.5)
    main.Position = UDim2.fromScale(0.5, 0.5)
    main.Size = UDim2.fromOffset(W - 40, H - 40)   -- стартуем меньше, для всплытия
    main.BackgroundColor3 = Color3.fromRGB(15, 15, 21)
    main.BorderSizePixel = 0
    main.ClipsDescendants = true
    -- Active заставляет окно поглощать клики, иначе нажатие по кнопке
    -- заодно бьёт/стреляет в игре — та же причина, что и в меню ZINKA.
    main.Active = true
    main.Parent = gui
    corner(main, 16)
    grad(main, ColorSequence.new{
        ColorSequenceKeypoint.new(0, Color3.fromRGB(22, 20, 32)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(12, 12, 18)),
    }, 60)

    -- дышащая переливающаяся обводка
    local ms = stroke(main, ACCENT, 1.6, 0.4)
    ms.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    TweenService:Create(ms, TweenInfo.new(2.0, Enum.EasingStyle.Sine,
        Enum.EasingDirection.InOut, -1, true), {Transparency = 0.12, Thickness = 2.2}):Play()
    local msGrad = grad(ms, ColorSequence.new{
        ColorSequenceKeypoint.new(0.0, Color3.fromRGB(150, 120, 255)),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(120, 220, 255)),
        ColorSequenceKeypoint.new(1.0, Color3.fromRGB(255, 120, 220)),
    }, 0)
    table.insert(conns, RunService.Heartbeat:Connect(function(dt)
        msGrad.Offset = Vector2.new((msGrad.Offset.X + dt * 0.06) % 1, 0)
    end))

    -- всплытие окна
    tw(main, {Size = UDim2.fromOffset(W, H)}, 0.28):Play()

    local function syncShadow()
        shadow.Position = main.Position
        shadow.Size = UDim2.fromOffset(main.Size.X.Offset + 46, main.Size.Y.Offset + 46)
    end
    table.insert(conns, main:GetPropertyChangedSignal("Position"):Connect(syncShadow))
    table.insert(conns, main:GetPropertyChangedSignal("Size"):Connect(syncShadow))

    --== шапка ==--
    local top = Instance.new("Frame")
    top.Size = UDim2.new(1, 0, 0, 62); top.BackgroundColor3 = Color3.fromRGB(12, 12, 18)
    top.BorderSizePixel = 0; top.Parent = main
    corner(top, 16)
    local topfix = Instance.new("Frame")
    topfix.Size = UDim2.new(1, 0, 0, 16); topfix.Position = UDim2.new(0, 0, 1, -16)
    topfix.BackgroundColor3 = top.BackgroundColor3; topfix.BorderSizePixel = 0; topfix.Parent = top

    -- переливающееся название чита
    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Position = UDim2.fromOffset(22, 9); title.Size = UDim2.fromOffset(300, 26)
    title.Font = Enum.Font.Michroma; title.Text = "ZINKA"; title.TextSize = 23
    title.TextXAlignment = Enum.TextXAlignment.Left; title.TextYAlignment = Enum.TextYAlignment.Top
    title.TextColor3 = Color3.fromRGB(255, 255, 255); title.ZIndex = 3; title.Parent = top
    local tGrad = grad(title, ColorSequence.new{
        ColorSequenceKeypoint.new(0.00, Color3.fromRGB(150, 120, 255)),
        ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 120, 220)),
        ColorSequenceKeypoint.new(0.50, Color3.fromRGB(120, 220, 255)),
        ColorSequenceKeypoint.new(0.75, Color3.fromRGB(180, 255, 180)),
        ColorSequenceKeypoint.new(1.00, Color3.fromRGB(150, 120, 255)),
    }, 0)
    table.insert(conns, RunService.Heartbeat:Connect(function(dt)
        tGrad.Offset = Vector2.new((tGrad.Offset.X + dt * 0.35) % 1, 0)
    end))

    local sub = Instance.new("TextLabel")
    sub.BackgroundTransparency = 1
    sub.Position = UDim2.fromOffset(24, 38); sub.Size = UDim2.fromOffset(320, 14)
    sub.Font = Enum.Font.Gotham; sub.Text = "вход по ключу  •  work.ink"; sub.TextSize = 11
    sub.TextColor3 = Color3.fromRGB(175, 175, 205)
    sub.TextStrokeColor3 = Color3.fromRGB(8, 8, 12); sub.TextStrokeTransparency = 0.4
    sub.TextXAlignment = Enum.TextXAlignment.Left; sub.ZIndex = 3; sub.Parent = top

    local headRule = Instance.new("Frame")
    headRule.Position = UDim2.fromOffset(0, 61); headRule.Size = UDim2.new(1, 0, 0, 1)
    headRule.BackgroundColor3 = ACCENT; headRule.BackgroundTransparency = 0.55
    headRule.BorderSizePixel = 0; headRule.ZIndex = 4; headRule.Parent = main

    local closeB = Instance.new("TextButton")
    closeB.Size = UDim2.fromOffset(30, 30); closeB.Position = UDim2.new(1, -42, 0, 16)
    closeB.BackgroundColor3 = Color3.fromRGB(30, 28, 40)
    closeB.Text = "×"; closeB.Font = Enum.Font.GothamBold; closeB.TextSize = 18
    closeB.TextColor3 = Color3.fromRGB(220, 210, 230)
    closeB.AutoButtonColor = false; closeB.ZIndex = 3; closeB.Parent = top
    corner(closeB, 8)

    --== перетаскивание за шапку ==--
    do
        local dragging, ds, sp
        top.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = true; ds = i.Position; sp = main.Position
            end
        end)
        top.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
        end)
        table.insert(conns, UIS.InputChanged:Connect(function(i)
            if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then
                local d = i.Position - ds
                main.Position = UDim2.new(sp.X.Scale, sp.X.Offset + d.X, sp.Y.Scale, sp.Y.Offset + d.Y)
            end
        end))
    end

    --== статус ==--
    local status = Instance.new("TextLabel")
    status.BackgroundTransparency = 1
    status.Position = UDim2.fromOffset(22, 74); status.Size = UDim2.fromOffset(W - 44, 36)
    status.Font = Enum.Font.Gotham; status.TextSize = 13; status.TextWrapped = true
    status.TextXAlignment = Enum.TextXAlignment.Left; status.TextYAlignment = Enum.TextYAlignment.Top
    status.TextColor3 = Color3.fromRGB(175, 175, 205)
    status.Text = "Нажми «Получить ключ», пройди по ссылке и вставь полученный ключ сюда."
    status.Parent = main

    --== поле ввода ==--
    local boxBg = Instance.new("Frame")
    boxBg.Position = UDim2.fromOffset(22, 118); boxBg.Size = UDim2.fromOffset(W - 44, 44)
    boxBg.BackgroundColor3 = Color3.fromRGB(24, 22, 34); boxBg.BorderSizePixel = 0
    boxBg.Parent = main
    corner(boxBg, 10)
    local boxStroke = stroke(boxBg, ACCENT, 1, 0.7)

    local box = Instance.new("TextBox")
    box.BackgroundTransparency = 1
    box.Position = UDim2.fromOffset(14, 0); box.Size = UDim2.new(1, -28, 1, 0)
    box.Font = Enum.Font.Code; box.TextSize = 15
    box.TextColor3 = Color3.fromRGB(235, 235, 245)
    box.PlaceholderColor3 = Color3.fromRGB(110, 108, 130)
    box.PlaceholderText = "вставь ключ сюда"
    box.ClearTextOnFocus = false; box.Text = ""
    box.TextXAlignment = Enum.TextXAlignment.Left
    box.Parent = boxBg
    box.Focused:Connect(function() tw(boxStroke, {Transparency = 0.15}, 0.18):Play() end)
    box.FocusLost:Connect(function() tw(boxStroke, {Transparency = 0.7}, 0.18):Play() end)

    --== кнопки ==--
    local BW = (W - 44 - 16) / 2

    local getBtn = Instance.new("TextButton")
    getBtn.Position = UDim2.fromOffset(22, 176); getBtn.Size = UDim2.fromOffset(BW, 42)
    getBtn.BackgroundColor3 = Color3.fromRGB(30, 28, 40); getBtn.BorderSizePixel = 0
    getBtn.Font = Enum.Font.GothamMedium; getBtn.TextSize = 14
    getBtn.TextColor3 = Color3.fromRGB(225, 220, 240)
    getBtn.Text = "Получить ключ"; getBtn.AutoButtonColor = false; getBtn.Parent = main
    corner(getBtn, 10)
    local getStroke = stroke(getBtn, ACCENT, 1, 0.6)

    local okBtn = Instance.new("TextButton")
    okBtn.Position = UDim2.fromOffset(22 + BW + 16, 176); okBtn.Size = UDim2.fromOffset(BW, 42)
    okBtn.BackgroundColor3 = Color3.fromRGB(150, 120, 255); okBtn.BorderSizePixel = 0
    okBtn.Font = Enum.Font.GothamBold; okBtn.TextSize = 14
    okBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    okBtn.Text = "Принять ключ"; okBtn.AutoButtonColor = false; okBtn.Parent = main
    corner(okBtn, 10)
    grad(okBtn, ColorSequence.new{
        ColorSequenceKeypoint.new(0, Color3.fromRGB(160, 130, 255)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 200, 255)),
    }, 15)

    -- подсветка при наведении
    local function hover(btn, over, base)
        btn.MouseEnter:Connect(function() tw(btn, {BackgroundColor3 = over}, 0.15):Play() end)
        btn.MouseLeave:Connect(function() tw(btn, {BackgroundColor3 = base}, 0.15):Play() end)
    end
    hover(getBtn, Color3.fromRGB(44, 40, 58), Color3.fromRGB(30, 28, 40))
    hover(okBtn, Color3.fromRGB(175, 148, 255), Color3.fromRGB(150, 120, 255))

    local hint = Instance.new("TextLabel")
    hint.BackgroundTransparency = 1
    hint.Position = UDim2.fromOffset(22, 228); hint.Size = UDim2.fromOffset(W - 44, 34)
    hint.Font = Enum.Font.Gotham; hint.TextSize = 11; hint.TextWrapped = true
    hint.TextXAlignment = Enum.TextXAlignment.Left; hint.TextYAlignment = Enum.TextYAlignment.Top
    hint.TextColor3 = Color3.fromRGB(115, 113, 135)
    hint.Text = "Ключ сохранится, повторно вводить не придётся. Enter — тоже приём."
    hint.Parent = main

    --==========================================================
    --  КУРСОР (перенесён из ZINKA один в один)
    --  Игра каждый кадр заново прячет и центрирует системную мышь ради аима киллера,
    --  поэтому в окне настоящий курсор бесполезен: он либо невидим, либо прыгает в
    --  центр. Освобождаем мышь, гасим системную иконку и рисуем СВОЮ стрелку. Крутится
    --  на RenderPriority.Last (после модулей камеры) и переставляет значения только
    --  когда они реально сбиты.
    --==========================================================
    local CURSOR_BIND = "ZINKA_KeyCursor"
    pcall(function() RunService:UnbindFromRenderStep(CURSOR_BIND) end)

    local zCursor = Instance.new("ImageLabel")
    zCursor.Name = "ZCursor"; zCursor.BackgroundTransparency = 1
    zCursor.Size = UDim2.fromOffset(34, 34)
    zCursor.Image = "rbxasset://textures/Cursors/KeyboardMouse/ArrowCursor.png"
    zCursor.ZIndex = 999; zCursor.Visible = false; zCursor.Parent = gui

    -- мягкое акцентное свечение под стрелкой, чтобы её было видно на любом фоне
    local zcGlow = Instance.new("ImageLabel")
    zcGlow.Name = "glow"; zcGlow.BackgroundTransparency = 1
    zcGlow.AnchorPoint = Vector2.new(0.5, 0.5); zcGlow.Position = UDim2.fromScale(0.35, 0.35)
    zcGlow.Size = UDim2.fromOffset(46, 46)
    zcGlow.Image = "rbxasset://textures/Cursors/KeyboardMouse/ArrowCursor.png"
    zcGlow.ImageColor3 = ACCENT; zcGlow.ImageTransparency = 0.4
    zcGlow.ZIndex = 998; zcGlow.Parent = zCursor

    local guiInset = GuiService:GetGuiInset()
    local cursorBound = false
    pcall(function()
        RunService:BindToRenderStep(CURSOR_BIND, Enum.RenderPriority.Last.Value + 1, function()
            if not main.Parent then return end
            if UIS.MouseBehavior ~= Enum.MouseBehavior.Default then
                UIS.MouseBehavior = Enum.MouseBehavior.Default
            end
            if UIS.MouseIconEnabled then
                UIS.MouseIconEnabled = false
            end
            local m = UIS:GetMouseLocation()
            zCursor.Position = UDim2.fromOffset(m.X, m.Y - guiInset.Y)
            zCursor.Visible = true
        end)
        cursorBound = true
    end)

    -- Возврат управления мышью. Обязателен: мы погасили системную иконку ради своей,
    -- и если её не вернуть, курсор останется невидимым до респавна — как зритель ты
    -- вообще ничего не сможешь нажать.
    local function releaseCursor()
        if cursorBound then
            pcall(function() RunService:UnbindFromRenderStep(CURSOR_BIND) end)
            cursorBound = false
        end
        pcall(function() UIS.MouseIconEnabled = true end)
    end

    --== поведение ==--
    local function setStatus(text, color)
        status.Text = text
        status.TextColor3 = color or Color3.fromRGB(175, 175, 205)
    end

    local function shutdown(res)
        releaseCursor()
        for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
        tw(main, {Size = UDim2.fromOffset(W - 40, H - 40)}, 0.2):Play()
        tw(shadow, {ImageTransparency = 1}, 0.2):Play()
        task.delay(0.22, function() gui:Destroy() end)
        result = res
    end

    getBtn.MouseButton1Click:Connect(function()
        local copied = pcall(setclipboard, CONFIG.KEY_LINK)
        if copied then
            setStatus("Ссылка скопирована в буфер. Открой её в браузере, пройди шаги и вернись с ключом.",
                Color3.fromRGB(120, 200, 255))
            getBtn.Text = "Скопировано ✓"
            task.delay(2, function() if getBtn.Parent then getBtn.Text = "Получить ключ" end end)
        else
            setStatus("Буфер недоступен. Ссылка: " .. CONFIG.KEY_LINK, Color3.fromRGB(235, 185, 95))
        end
    end)

    closeB.MouseButton1Click:Connect(function() shutdown(false) end)

    local busy = false
    local function submit()
        if busy then return end
        local key = (box.Text:gsub("%s+", ""))
        if key == "" then
            setStatus("Поле пустое — вставь ключ.", Color3.fromRGB(235, 185, 95))
            return
        end
        busy = true
        okBtn.Text = "Проверяю…"
        okBtn.AutoButtonColor = false
        setStatus("Проверка ключа на сервере work.ink…", Color3.fromRGB(175, 175, 205))

        local ok, msg = validateKey(key)
        if ok then
            setStatus(msg, Color3.fromRGB(125, 230, 150))
            okBtn.Text = "Принято ✓"
            ACCEPTED_KEY = key
            saveKey(key)
            task.wait(0.7)
            shutdown(true)
        else
            setStatus("Ошибка: " .. msg, Color3.fromRGB(255, 115, 115))
            okBtn.Text = "Принять ключ"
            busy = false
            -- короткая тряска поля, чтобы промах был заметен
            local base = boxBg.Position
            for _, dx in ipairs({8, -8, 5, -5, 0}) do
                boxBg.Position = base + UDim2.fromOffset(dx, 0)
                task.wait(0.03)
            end
            boxBg.Position = base
        end
    end

    okBtn.MouseButton1Click:Connect(submit)
    box.FocusLost:Connect(function(enter) if enter then submit() end end)

    -- ждём решения пользователя
    repeat task.wait(0.1) until result ~= nil
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
        ACCEPTED_KEY = saved
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
    stop("Доступ закрыт — ключ не введён.\n\nПолучи ключ здесь:\n" .. CONFIG.KEY_LINK,
        CONFIG.KICK_ON_NO_KEY)
end

--==========================================================
--  ЗАГРУЗКА ОСНОВНОГО СКРИПТА
--==========================================================
notify(("Игра: %s\nЗагрузка скрипта..."):format(placeName), 4)

local function addParam(url, kv)
    return url .. (url:find("?") and "&" or "?") .. kv
end

local scriptUrl = CONFIG.SCRIPT_URL
-- Ключ уходит раздатчику: без него скрипт не отдадут.
if ACCEPTED_KEY then scriptUrl = addParam(scriptUrl, "k=" .. ACCEPTED_KEY) end
if CONFIG.BUST_CACHE then scriptUrl = addParam(scriptUrl, "v=" .. tostring(os.time())) end

local source = httpGet(scriptUrl)
if not source then stop("Не удалось скачать скрипт. Проверь интернет.", false) end
if source:match("^%s*<") then stop("Сервер вернул страницу вместо кода. Проверь ссылку.", false) end

-- Раздатчик отвечает 200 с заглушкой вместо кода ошибки: часть исполнителей
-- роняет HttpGet на любом не-2xx, и юзер увидел бы ошибку движка вместо текста.
local denied = source:match("^%-%-%[%[DENIED:([%w]+)%]%]")
if denied then
    -- Сбой инфраструктуры или всё-таки плохой ключ? От этого зависит,
    -- кикать ли и стирать ли сохранённый ключ.
    local infra = denied:match("^source") or denied == "validator" or denied == "noconfig"

    local reasons = {
        badkey    = "Ключ не похож на настоящий.",
        invalid   = "Ключ недействителен или просрочен.",
        foreign   = "Ключ выдан не для этого скрипта.",
        expired   = "Срок действия ключа истёк.",
        validator = "work.ink сейчас недоступен, попробуй позже.",
        noconfig  = "Раздатчик не настроен — напиши автору.",
    }
    local text = reasons[denied] or (infra and "Исходник недоступен — напиши автору."
                                           or ("Отказано: " .. denied))

    if infra then
        -- Ключ мог быть нормальным, стирать его не за что.
        stop(text, false)
    else
        clearKey()
        stop(text .. "\n\nПолучи новый ключ здесь:\n" .. CONFIG.KEY_LINK,
            CONFIG.KICK_ON_NO_KEY)
    end
end

local chunk, compileErr = loadstring(source, "@" .. CONFIG.NAME)
if not chunk then stop("Ошибка компиляции:\n" .. tostring(compileErr), false) end

local ranOk, runErr = pcall(chunk)
if not ranOk then stop("Ошибка выполнения:\n" .. tostring(runErr), false) end

notify("Скрипт успешно загружен", 4)
