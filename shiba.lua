-- Shiba.lua
-- Based on Calico
-- Experimental Lua & LuaSQL version
-- Lua 5.1.5

---- Global Goodies

require 'bin/conf'
driver = require 'luasql.mysql'
db = driver.mysql ()
con = nil

---- Helper Functions

-- Removes whitespace on the edges of a string
function trim (s)
  return s:match ('^%s*(.-)%s*$')
end

-- Compacts multiple whitespace characters
function compact (s)
  return s:gsub ('%s+', ' ')
end

-- Splits a string into an array-like table on a delimiter
function split (s, d)
  local t = {}
  d = d or '%s'
  
  for str in s:gmatch ("([^"..d.."]+)") do
      t[#t+1] = str
  end
  
  return t
end

-- String interpolation using table subs
function interp (s, t)
  return (s:gsub ('($%b{})', function (w) return t[w:sub (3, -2)] or w end))
end

-- Limits a number to boundaries
function bounds (l, n, h)
  return math.max (l, math.min (n, h))
end

-- Empties a table in place
function empty (t)
  for k in ipairs (t) do
    t[k] = nil
  end
end

function reconnect()
  if con then
    con:close()
    con = nil
  end
  
  con = assert ( db:connect(DB_NAME, DB_USER, DB_PASS) )
end

-- Does a SQL query with automatic reconnecting
function doSqlQuery(q)
  if con == nil then
    reconnect()
  end

  local keepGoing = false
  repeat
    keepGoing = false
    local result, err = con:execute(q)
    if result == nil and err == "LuaSQL: error executing query. MySQL: MySQL server has gone away" then
      print("Re-establishing MySQL connection")
      reconnect()
      keepGoing = true
    elseif result ~= nil then
      return result
    else
      error(err)
    end
  until not keepGoing
  error("Left loop without returning")
end

---- Main Table Object & pseudo global settings

Shiba = {}

---- Queue
Shiba.queue = {}

---- Commands
Shiba.commands = {}

-- Audio Related

Shiba.commands['volume'] = function (event, args)
  local vol = tonumber (args[1])
  local setting, percentage = true

  if not vol then
    vol = piepan.Audio.Volume ()
    setting = false
  end
  
  if setting then
    vol = bounds (0, vol, 1)
    piepan.Audio.SetVolume (vol)
  end
  
  percentage = interp ('Volume: ${p}%', {p = math.floor (vol * 100)})
  piepan.Self.Channel.Send (percentage, false)
end

Shiba.commands['find'] = function (event, args, offset)
  local request, response, query, found
  local search = args[1]
  local offset = offset or 0
  local dbtable = con:escape (TABLE_AUDIO)
  local qsubs = {t = dbtable, o = offset}
  local message = [[
  <table border="1" cellpadding="5"><thead><tr>
  <th width="50%">NAME</th>
  <th width="50%">CMD</th>
  </tr></thead>
  ]]

  if not search then
    query = 'SELECT name, cmd FROM ${t} ORDER BY name ASC LIMIT 20 OFFSET ${o}'
    query = interp (query, qsubs)
  else
    query = 'SELECT name, cmd FROM ${t} WHERE name LIKE "%${s}%" ORDER BY name ASC LIMIT 20 OFFSET ${o}'
    qsubs['s'] = con:escape (search)
    query = interp (query, qsubs)
  end
  
  request = assert ( doSqlQuery (query) )
  response = true
  
  while response do
    response = request:fetch ({})
    
    if response then
      found = true
      
      local name, cmd
      name = response[1]
      cmd = response[2]
      
      message = message..'<tr><td width="50%" align="center">'..name..'</td>'
      message = message..'<td width="50%" align="center">'..cmd..'</td></tr>'
    end
  end
  
  if found then
    message = message..'</table>'
    event.Sender.Send (message)
    Shiba.commands['find'] (event, args, offset + 20)
  else
    event.Sender.Send ('End of results.')
  end
end

-- Queue related
Shiba.commands['shut up'] = function (event, args)
  if piepan.Audio.IsPlaying () then
    piepan.Audio.Stop ()
  end
  local count, grammar, response = #Shiba.queue
  
  empty (Shiba.queue)  
  piepan.Self.Channel.Send ("Okay, sorry. :(", false)
end

Shiba.commands['list queue'] = function (event, args)
  local count = #Shiba.queue
  
  if count == 0 then
    piepan.Self.Channel.Send ('Queue is empty.', false)
    return
  end
  
  local text = (count == 1) and 'entry' or 'entries'
  local response = interp ('Queue has ${n} ${t}:', {n = count, t = text})
  
  for _, v in ipairs (Shiba.queue) do
    response = response..' ['..v..']'
  end
  
  piepan.Self.Channel.Send (response, false)
end

-- Movement related
Shiba.commands['move here'] = function (event, args)
  local cur, des
  cur = piepan.Self.Channel.ID
  des = event.Sender.Channel.ID
  
  if cur ~= des then
    piepan.Self.Move (piepan.Channels[des])
  end
end

Shiba.commands['get id'] = function (event, args)
  local sender = event.Sender
  local id = sender.Channel.ID
  
  sender.Send (interp ('You are in channel ${c}.', {c = id}))
end

-- Chat related
Shiba.commands['help'] = function (event, args)
  local sender = event.Sender
  local help = [[
  Help has arrived!
  <br /><br />
  <b>do [COMMAND]</b> - Call literal commands. e.g., <i>do stop</i>
  <br /><br />
  Some <b>do</b> commands take extra parameters.
  These can be passed in by prefixing a <b>+</b> onto
  the parameter, following the command. e.g., do volume +0.5
  <br /><hr /><br />
  <b>say [COMMAND]</b> - Print associated text. e.g., <i>say hello</i>
  <br /><hr /><br />
  <b>play [COMMAND]</b> - Play associated audio clip. e.g., <i>play theme</i>
  <br /><hr /><br />
  Multiple commands can be sent in one message
  by splitting them up with a semi-colon ( <b>;</b> )<br />
  e.g., play this; say that; do something
  <br />
  ]]
  
  sender.Send (help)
end

Shiba.commands['show'] = function (event, args)
  local cmds = {}
  local sender = event.Sender
  local response = 'Commands:'
  
  for k in pairs (Shiba.commands) do
    cmds[#cmds+1] = k
  end
  
  table.sort (cmds)
  
  for _, v in ipairs (cmds) do
    response = response..' ['..v..']'
  end
  
  sender.Send (response)
end

Shiba.commands['echo'] = function (event, args)
  for _, v in ipairs (args) do
    send(event, v, true)
  end
end

-- Database related

Shiba.commands['reconnect'] = function (event, args)
  reconnect()
  
  if con and event then
    print ('Shiba has found the bone.')
    event.Sender.Send ('Database connection back online.')
  end
end

function send(event, msg, forcePublic)
  local public = false
  for _, v in ipairs(event.Channels) do
    v.Send(msg, false)
    public = true
  end
  for _, v in ipairs(event.Trees) do
    v.Send(msg, true)
    public = true
  end
  if not public and not forcePublic then
    event.Sender.Send(msg)
  elseif forcePublic then
    piepan.Self.Channel.Send(msg, false)
  end
end

Shiba.commands['query'] = function(event, args)
  if (event.Sender.Name == ADMIN_NAME) then
    for _, v in ipairs(args) do
      local result, err = con:execute(v);
      if result ~= nil then
        if type(result) == "number" then
          send(event, 'Query OK, '..result..' rows affected.')
        else
          send(event, "Query OK.")
        end
      else
        send(event, err)
      end
    end
  else
    send(event, 'No.')
  end
end

---- Core funcionality

-- Issue Command
Shiba.issueCommand = function (event, command)
  local args = split (command, '+')
    
  for k, v in ipairs (args) do
    args[k] = trim (v)
  end
  
  local cmd = table.remove (args, 1)
  
  if Shiba.commands[cmd] then
    Shiba.commands[cmd] (event, args)
  end
end

-- Talk Back
Shiba.talkBack = function (query)
  local request, response
  local dbtable = con:escape (TABLE_TEXT)
  local cmd = con:escape (query)
  local qsubs = {t = dbtable, c = cmd}
  local query = interp ('SELECT response FROM ${t} WHERE cmd = "${c}"', qsubs)
  
  request = assert ( doSqlQuery (query) )
  response = request:fetch ({})
  
  if response then
    piepan.Self.Channel.Send (response[1], false)
  end
end

-- Get File Info
Shiba.getFileInfo = function (clip)
  local request, response
  local assoc = {}
  local dbtable = con:escape (TABLE_AUDIO)
  local cmd = con:escape (clip)
  local qsubs = {t = dbtable, c = cmd}
  -- I know ORDER BY RAND() is bad practice, but it's an easy patch to allow multiple
  -- audio entries with the same command for random selection.
  local query = interp ('SELECT dir, filename, ext FROM ${t} WHERE cmd = "${c}" ORDER BY RAND() LIMIT 1', qsubs)
  
  request = assert ( doSqlQuery (query) )
  response = request:fetch ({})
  
  if response then
    assoc['dir'] = response[1]
    assoc['filename'] = response[2]
    assoc['ext'] = response[3]
  else
    assoc = false
  end
  
  return assoc
end

-- Play Audio
Shiba.playAudio = function (clip)
  if piepan.Audio.IsPlaying () then
    if #Shiba.queue < 10 then
      table.insert (Shiba.queue, clip)
    end
    return
  end
  
  local fileInfo, fpath = Shiba.getFileInfo (clip)
  
  if not fileInfo then
    Shiba.playNext ()
    return
  end
  
  local fsubs = {
    d = AUDIO_DIR,
    s = fileInfo['dir'],
    f = fileInfo['filename'],
    e = fileInfo['ext']
  }
  
  fpath = interp ('${d}/${s}/${f}.${e}', fsubs)
  piepan.Audio.Play ( { filename = fpath, callback = Shiba.playNext } )
end

Shiba.playNext = function ()
  local count = #Shiba.queue
  local nextInLine
  
  if count > 0 then
    nextInLine = table.remove (Shiba.queue, 1)
    Shiba.playAudio (nextInLine)
  end
end

---- Event Handlers

--[[
Splits message into multiparts
Issue appropriate low level command per part
--]]
Shiba.delegateMessage = function (event)
  if event.Sender == nil then
    return
  end
  
  local msg = event.Message
  msg = compact (trim (msg))
    
  local cmds = split (msg, ';')
  
  for _, v in ipairs (cmds) do
    v = trim (v)
    
    if v:sub (1, 2) == 'do' then
      Shiba.issueCommand (event, v:sub (4))
    end
    
    if v:sub (1, 3) == 'say' then
      Shiba.talkBack (v:sub (5))
    end
    
    if v:sub (1, 4) == 'play' or
       v:sub (1, 4) == 'okay' then
      Shiba.playAudio (v:sub (6))
    end

  end
end

Shiba.connected = function (event)
  print ('Shiba is barking.')
  Shiba.commands.reconnect ()
  piepan.Audio.SetVolume (0.5)
  piepan.Self.SetComment ('I\'m a bot! Type <b>do help</b> for help on how to use me.')
  piepan.Self.Move (piepan.Channels[3])
end

---- Events

piepan.On ('connect', Shiba.connected)
piepan.On ('message', Shiba.delegateMessage)
