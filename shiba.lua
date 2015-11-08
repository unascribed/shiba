-- Shiba.lua
-- Based on Calico
-- Experimental Lua & LuaSQL version
-- Lua 5.1.5

---- Global Goodies

require 'bin/conf'
driver = require 'luasql.mysql'
db = driver.mysql ()
con = nil
recentMessages = {}

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
  send(event, "Okay, sorry. :(")
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
  msg = trim(msg)
  if msg:sub(1, 2) == 's/' then
    local s = split(msg, '/')
    local needle = s[2]
    local replacement = s[3] or ""
    for i=#recentMessages,1,-1 do
      local v = recentMessages[i]
      if string.find(v.text, needle, 1, true) then
        v.text = string.gsub(v.text, needle, replacement)
        send(event, "Correction, "..v.sender..": "..v.text);
        return
      end
    end
    send(event, "Can't find anything to correct.")
    return
  end
  if #recentMessages > 50 then
    table.remove(recentMessages, 1)
  end
  table.insert(recentMessages, {text=event.Message, sender=event.Sender.Name})
  msg = compact(msg)

  local cmds = split (msg, ';')
  
  for _, v in ipairs (cmds) do
    v = trim (v)
    
    if v:sub (1, 2) == 'do' then
      print(event.Sender.Name..": "..v)
      Shiba.issueCommand (event, v:sub (4))
    end
    
    if v:sub (1, 3) == 'say' then
      print(event.Sender.Name..": "..v)
      Shiba.talkBack (v:sub (5))
    end
    
    if v:sub (1, 4) == 'play' or
       v:sub (1, 4) == 'okay' then
      print(event.Sender.Name..": "..v)
      Shiba.playAudio (v:sub (6))
    end

    if v:sub (1, 4) == 'grep' then
      for _, q in ipairs(recentMessages) do
        if (q.sender == v:sub(6)) then
          event.Sender.Send(q.text);
        end
      end
    end

  end
end

Shiba.connected = function (event)
  print ('Shiba is barking.')
  Shiba.commands.reconnect ()
  piepan.Audio.SetVolume (0.5)
  piepan.Self.SetComment ([[
    <img src="data:image/JPEG;base64,%2F9j%2F4AAQSkZJRgABAQEAYABgAAD%2F2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH%2F2wBDAQEBAQEBAQEBAQEBAQEB AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH%2FwAAR CACoASwDASIAAhEBAxEB%2F8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL%2F8QAtRAA AgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkK FhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWG h4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4%2BTl 5ufo6erx8vP09fb3%2BPn6%2F8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL%2F8QAtREA AgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYk NOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOE hYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk 5ebn6Onq8vP09fb3%2BPn6%2F9oADAMBAAIRAxEAPwD%2Bcj9nXw5%2FxW2lE%2FX8Rx%2BZ78fpX9AHg%2Bxz 4b%2F%2FAFHvn%2Bv5%2B9fz%2FwDwH1z%2BzPG309Mfrn%2Bftxx1%2Ffj4e339p%2BG%2F1%2Fz%2FAE%2FHjtRivtfP%2FwBu Ocqzf8hM%2FUV6BpnU%2FQ%2FzrzfU%2Bo%2Bg%2FnXbaDP9D%2FP8uD%2BvvXl4bp%2FX8wHR%2BR7%2FAK%2F%2FAFqrzQf0 5%2Fx4%2FXHt6GtCq9dgGfXa%2BCb7%2FipPCul6kf8AiVap4o0j%2FwAGmmf2t%2BP1%2FIVzXke%2F6%2F8A1qta bqv%2FAAjOpaVqn%2FQL1T%2FmKdf6cfmB3r4%2Fje3%2BrWZt6xXs7%2BnuXX4M%2Bj4Ru%2BI8rS3a09baH2x%2B 0h8Yh8INN0rVP7L9%2BMfr%2BOK634G%2FtG%2BF%2FiZ4b%2FsvU%2Buqf5%2Fw9vfNfJf7YH%2FFzPhKNV03%2FiVa r%2FZY9vfH5Zr8K%2F2Xfi3488C%2FH7StL03VP7K%2F4mn9lap4R1T6D%2FmFemcc%2FlV4LM%2BanCGCd8ln CMXbW7cYp6ddntp520PQnlvJUnPbOYzlJva1mnaWll5beh%2Bgv7fv7Of%2FAAjPjf8A4TzwT%2FxK v7L%2FAOJrpmr6UOuqf8hb%2FiVdumc%2F5Fc3%2Bzf%2B1D4X%2BJnhv%2By%2FG2qaTpXj%2FS%2BdUOqf8Sr%2B1CT%2F AMhTSuP6dvwr9F%2F2tLHVPE3wlGqe2kar2PGP5%2B3f8M1%2FOR4q%2BFeqeJvEmqjwT0%2FtXr%2BnX157 9fbqfwJ8UrgHinN8FhGlkspczu7Ozak7fP8ArQ%2FdY8Lf6%2FcLZTjY2lnUYqLdtNFZXa0tdJPa 9tT92Kjhg6f4fkP6n8ye1fE%2FgPx%2F488M%2BG9K8L6lqn%2FCVarpf%2FEq%2FwCQXj%2By%2FwDuKY967ab4 xappn%2FIS1T%2Fia9f7I0vnSx2P%2FE06fz96%2Bm%2F4mJ4KWn9l5%2B2tLrZvTbTbTTTovl8J%2FwAQA42v e%2FD1r31Sv82lv38z6r%2Bzn0H5D%2FGj7OfQfkP8a%2BFb34%2FePP7S%2FwCJbqn0Gl6X2x%2Fj0Feo%2BG%2Fi P8UBx4kOk5%2F6imf7UOen5%2F8A6vcwv0ieC3pj8p4gV%2Bulo3srvXpvr2V2LE%2BBPGullw%2B7PSy1 b0t6N6We9769%2FpSivGP%2BFt6oef7L%2FtX0%2FTIx756dPrWJrHxb%2FwCEm%2F4pfTdL%2FsrVdU1T%2Byjy B%2BHX%2FPpya95%2BNfBs8C1l2atSatGLWqbsopuzV1pe2t%2Bt9H5eE8HuMo41YPMcrXJFqTa25Vyt 2fbdr5PofWnw98D6p4503%2B1NR%2Fsn%2BytU%2FwCQX%2Fan%2FQL0v%2FP0%2FCvLvHn7K%2Bl%2BOf7V0vTc%2FwBl dP7I6f8AlU%2FM88jivpD42fE3%2FhT%2FAIJ8K%2F8AEr%2F5hekHp2%2F6hX%2FQYI9Pz4FfPGg%2FtJ6X4G8N %2FwDFSf8AIVH9r%2F2p%2FwBAvS%2F%2BYtpWl%2F2p%2Fbn%2FABJ9a%2F5BefD3P86%2BZyLwxwOdyln%2BdZt%2Fws58 7x0ezacb6bWsr32631Ppsy45x2SYxZBkn%2FImirSSvvGyl17p6dbdT8T%2FANqL4EeKPgb430o6 bqmraVpWP7U0v%2By%2F%2BQp%2FxNO%2BD%2FntX6z%2FAAB%2BI3%2FCzPhJ4V8UH%2FkK%2FwDIK1T%2FALCmlA%2FXgjtX v%2F7RXwk8L%2FtV%2Fs36r8ZPBP8AxNdV0v8A4pXVPXS9U0vtnPHH51%2BYn7Cs%2BqeGdS%2BKnwv1Lr%2Fx KNV0vSNU%2FwDBTqg9s%2F8AEr9%2FrmvpchwuN4N4mWR392Wz2TTts9nfyvr6Hm8T4p8T8MvO%2FtZF e60ve6W3bVrz1P0Xn7%2F8DryXXvB31H6j%2BX9etetTT9f8fzP9B%2BQHesS86fiP5Cv1%2B%2Ffd6%2F5n 4ne%2BvfX7zktB0r%2BzPUfz%2FwA8df8AHnpJp%2F6cf48%2Fpn39BR5Hv%2Bv%2FANatKHw5qn8uPp0H4%2Fr0 Fb3S3a%2B8DFo8%2FwBv0%2F8Ar11kPg7VP8%2Fr7c5%2FTvVbWPCuqaZnue3GPzP%2BRxRdd1%2FX%2FDr7wOc8 %2FwBv0%2F8Ar1Xqx5Hv%2Bv8A9aq9MCrN97%2FPoKhqxVegDIm6H6D%2BdYt51%2FAfzFdHN93%2FAD6ivFPi F4x%2FszTc%2Fj%2BHrjr2x3HvjqHQcl8QvGP9mf8AEr00f1%2FT%2BZr5vm%2F4mepZ%2FDuP8%2Fz%2BlJN4i%2FtP Us9%2BnH9en%2F6%2BK9b0fRNL0z%2FsKj274%2Fzx2yT0roA5KHQ%2F7Lx%2BfQf5H9e1cLN98%2FQV6%2FrPf%2FP9 6vPn6j6f1Nc4H5wfB%2Bcf8Jtz%2Fk%2Fy5%2FX2r%2BgL4M3oHhvPPTHT%2Bv8AT%2BnFfzfeD9V%2FszxJpXQ%2B 3P0%2FyfSv3L%2BAPjj%2FAIpv%2FwCuf5n%2BXb6ZroxX2vn%2FAO3HJhuvp%2Bp7Z4qn9fcf%2FWOP1H610ng%2B %2B%2Fx%2FqMf1x%2F8AXry7WP7U1PIP4fpxnH%2BfevSPB9h0%2FwA9%2B3v9Oc1551nrNFLZwf5%2F%2Bv1wfpjn t2s%2BSv8AnP8AjXQc5V8%2F2%2FT%2FAOvSwwf2n%2FxKx%2FzFM%2F8A1uh%2F%2BtxRNBx%2Fn%2BfqPp7HIqzoOqnT NT0rVD%2FxNf7K1T%2BWf%2FrdMe%2FNeNm2FWNyPOcDLblb7uyWq%2F4GvQ9TKcS8FmGUY1b80dNnvFK%2B nnbXbf0%2BxrzwBpfib4J6Vpf%2FACCtW0v0%2FwCgp6f2p%2BOO9fzo%2FtIeB9U%2BGfxI0rxRpvOq%2FwBq f2rpZH%2FMU%2F4mn%2FMK%2FLt3461%2BxniX4xY8barpem6pq2laVqv9kf2XpGl4%2FL%2FP%2BNYkPw60rxz4 k%2F4Tz4kaXpP%2FABKsf2XpH6f8gv8AXNfzdS8TsnybB5Zl%2BCu5ZE5p31Tlezv3d%2B%2Fe2x%2FQ9Pw7 zbHYzM8fjbWz5Ras17qajtrppbt8mdt4k8Vap8X%2FAIJ%2BFdL1L%2FiVaVqul6R%2FwlH9qf8AIU1T VP8AoF8cnH8%2BlfLupfDnS9Mz%2FwASv%2By9Kz00vv0%2Fl2%2FOvuG80PVP7NOqDt%2FxKtL%2FAOgXx1Gl H%2F63p04r5d%2BLUH9m%2FwDIS%2FT%2FAKBeP%2Bgp%2Bnt61%2FL%2FAB1n2dcS559fxt1GUr6aJptWvb8rdbtn 71wbhcFw3gVkeCSbS1drpOyb1eq1%2FwCH3R836xY%2F2Z%2F1Cv5fn%2FnnnPp5LZ6H%2FwAJz0%2F5BX%2Bf fr%2FxNR%2F9bmvOfFPj7U%2FE2pHwvp2cf2n%2FAMTM6pjnTM9P%2FTb0wRg%2BtfXWg%2BFdL0vw2dL9D7f5 %2FD0zXJZ4KMW%2FtRTtfVeqeydrrutfh3%2BrPC72x0vwN%2Fav%2FCOfTVP%2Bgpqv049evTtiuSvPGOqf %2BVTp7j3%2FAM%2Fjxn1HXtKH%2FE16arz2z%2F0FD%2Bnb%2FPHhXjGD%2BzP%2BQbz0%2FH8SMe31rqwyeOto7Oyv rbWyd27%2BVuxP1pYNq9n9z69Nev5Ff4v%2FABF8T6b4K0vVPDhI0r%2B0idTP%2FMU0s4H9pjoeDz3x nrXzL%2Fw1D%2FZnH9qE%2FwDEr%2F8AKp%2Fk%2FwCSK9s03XNU0z%2FiV6l%2FyCtUP%2FII%2FwD1Efn%2FAEFcB8Qv 2c9L1T%2FiqPDWMdf%2FAObc%2FwBPav0bhh8MZMo4LPIpNNtSV3dtxtdu60dtktL3u9vjOKMVnONU sbkbunG0vJWs7Jfm%2BrvfQ%2FZ74zeP9L8c%2Fsc%2BAPHmp%2BKP7V%2F4RjwvpB0vH%2FIU1Q%2F8IudJzqp%2F zx%2FYGeK%2FBDxh8TdU%2FtP%2FAImWqavquq9v%2BoX%2FAMTT%2B1scdPp69c19sfCTxV%2Fwg3gnVfC%2FiT%2Fi a6UdL%2F5BOqc5%2FsvnH%2BeenXmvyO%2BJF9nxJqvUf2pqgx%2BH6c54r%2BqODc0jm%2BBi425Y25HdWSS0 tbTSyvb5vU%2Fk3P8ACyynHty1lK7lfW7b1%2B5u9%2FzP64v%2BCW3j%2FwD4W%2F8AsT%2FGnS%2F7K%2F4mvhfx 6NK1TSD1%2FwCQXpOraX%2F3Gv8AiaY%2Bn1r8oPB99%2Fwg37dX9l6b%2FwAzR%2FbGlappGl6p%2Fap0s%2F5%2F zziv1F%2F4Iz%2BB%2FwDhUH7CvxA%2BKHjb%2FiV%2F8LQ1T%2B1NL%2FtT%2FmKaX4X%2FAOJT4X%2Fsrr1P9qfl2r8q IvEel%2F8ADY3hXVD%2FAMxTxTq%2F9l%2B%2BqD%2FoK%2Bn%2FACFPbPtmubjDNF%2FrTwkk7vRSa%2BSV3vou%2FmdP DOGb4Y4tWuuqjvd23Sejd%2By3R%2Bqs33f8%2BorN8j3%2FAF%2F%2BtW5P3%2F4HXrXw98D%2FANp59h7f596%2B 64mz%2FBcNYGONxrXM0tLrsmnbtru1b7z8vyvK8bjcdbpe3y02T7X26bemJ4J%2BGWqan%2FnPc%2FX9 B%2BVfXuj%2FAAyzpw7%2FAKdf8f0%2FKvSPCvg7%2BzP7Kz3%2FAMnPH4%2BnpXscNj%2Bufr0z9fr%2Bvavyj%2FiI rxequvPbTS3XVbPdLW%2FkfT4nIfqlra36aPt037W03PjnXvhl%2FZmpaTqn%2Bfp7nt06VzfjDwP%2F AJ%2Fw9ee54%2FCvti80r%2Bn1%2FL05555ridS0Pr%2Fnt68Z%2FwAmvTwnHi6vte716WWvXy%2BTfU83%2Byn2 X9W8vNfej4M1j4c%2F8S3g%2FwCf5dcDj%2BeK8T1Lw3%2FyFdU%2BmD%2BvGR%2BP9e9fpleeFf8APbn9e5%2Fx rwrxJ4H%2FAOQr%2FwDr%2FXv7djjB5r7HK%2BMsDjLJtK%2B%2Bul9Oz00%2FHfY5MVlbXy0va3a352%2Fqx8Gz dT9R%2FKoK7PxJpX9makTwOf0%2FDntzXifjbxV%2FZhP9B09iMd%2B9fZ4TFXSad07Nf0%2Fla%2F8AwDw7 Pa2vYxPG3ir%2Byx1z%2FwDX9Pp9f6V8heJL7VNTx%2FPr%2BX4960vEniP%2B09S5z26%2F1HHHv%2FhXbeFf Dn9mY1TUvrz1469%2F8%2FhXYdB5LZ%2BBxpn%2FABND9f8A6%2BcY%2FwAT%2BFYmpX2qabn8c54%2FM%2Fl0OPpX 1Fe%2F%2FFf1ridS8K6Xqff378df89xQB88TeMdU6d%2FXvzj%2FAAx%2BOaxP%2BEx9%2FwBP%2FrV6jrHw5%2Fz6 n07cc%2FX39PNZPA2qFjn%2Bn9f8%2FjXQB%2BSGm33%2FABMieeOnX9fz%2FwA9%2FwBp%2FwBle%2B%2FtPTdKI7f5 %2FPn07GvxG03of8%2Fwiv1f%2FZL1X%2FkFdeM%2Fr%2Fnj1ozP7P8AXY5MLs%2FT9WfsHZ%2BFO3%2BfTP8APOfr W3Z6V%2FZnr%2F8AXxj8f8%2FjyWj%2BKsabkdu36f0FaX%2FCS%2F5%2FyK8FYvBXS2enVaM6ztKgmn4%2Fz%2FL1 P19zgVzf%2FCSH0P6%2F4VWm1z%2BuBj6Y4x9M8e49a6Fi8E7W0btbVaP8P0A25p%2Bf8%2Fy9B9fc5NaX hXQ9U8c%2BJNK8L6aP%2BJrqn%2BevfseMdu9eXXniPt%2Fn2%2F8Arc%2FUda%2FRf9lfwR%2FZnhv%2FAITzUh%2Fx NdUz%2FwBwvS8%2Fp%2FT8a%2BE8RuMI8OZG4YH%2FAJHNRW1S1TVradbPXTRdD6ngzInxHnabulBp66JJ Na62t%2BHqZsPwq8L%2BBtN%2F5Bf9q%2BKtU%2F5i%2BqD3%2FwCJp%2FTv06mtLwr4O1TxPqX%2FACC8nHX%2FADn%2F AA9DXSXn%2FEz%2FALV41b%2BfTPHT%2FwCt7Zr5Cg%2F4KP8AwG8M%2FtReFf2c9S%2F4Wx4U8fnxRpHhT%2B19 U0vS%2FwDhA%2F8AiqMf2XpfX%2FmZv%2BJXj%2Filuur1%2FK%2FDHB2O4ox8pyVlKTk1ayu5K%2FZLe2%2Bp%2FSme 8UYPhjAKLleUYqKu3o0ktE33128rdv078VfBb%2Fimyf7U%2Fsof9Qv%2FAKBXT9P1zmvyg%2FaE8K%2F8 S3xVqn9fp3z%2Blfsr%2B0JPqvhnwTg4OdLP9qD%2FACO34c%2FjX4n%2BNp9U8TeG9VGon%2FiVapqmf%2Frc 9fXNeB4m5DhOGs6jgUm27bJ799ref3X7vs8O8%2Bxuc4R49tWvu%2Bza01d9fx3Z8K%2FA3wB%2Fwk3j b%2FhKNS5%2FtTVP%2BJX07e2MHP8An0r9KfDf7NvjzxN%2Fwiul6bpf9q%2F8hftjJ%2F5BP9qc8evp3rrf 2afgDpeqeJNK0v8Asz8v%2BgX%2FANBPv0%2Fx98fqb4v1X%2FhUGm6V%2FwAI31%2FP%2FoLfl%2FP35FHB3AeN 4xxXM0%2BRddUuVWT12ei1%2BbR0cd%2BIj4afLgX71kmnvd2T8903by%2BR%2BUHir9lf%2FhBvDX%2FFSaXj %2FiV%2F8TTB%2FwCop%2F8AfTVPbtmvyg%2BJGh6X4Z5%2F4lP%2FACFAf7H0v%2B1NV%2FtTS%2F8AoKf2p9f8mv3C %2BJH7Sel%2FF%2FTdV%2FtLVP8AkF%2F2v%2FzFP6df8%2FWvyy%2BJHwd0vxN%2FxNNN%2FtX241TSwe%2Fcf8JB%2FOvM 4nymfDGdfUrf8IisudJ9LfaSto4vq%2FyDg7iDF51g%2Fr2PkuZ2tHmXWz2vdataWWx%2BfUOlf9xX n%2FmFZ6%2F5yPy%2FD1H4bz%2F2Z%2FxK%2FEmdV0r%2FAKBHvn9Px%2FKq15oeqeGdS%2FszUtL4%2Buf%2FANX5%2B1be sf2Xpn8%2F7JPQ%2FwDUL71xYrFLGr3e2mzeiutfKysfaYZ7XdlfXXT7QfEL4c%2F2Z%2FxNNN%2F5BWqY H%2Bfp7145N%2BzL4X0z4b%2F8J5%2Fan9q%2BK%2FFGqf8AcK%2F4mn%2FQK%2Frnk9AK%2FQX4M2P%2FAAnP%2FEr1P8eg 6YH19a8l%2BNnwe8UeBtN1XS9N%2FwCRV1Q5%2FwCJX%2FzCz1yfz5P4jpXbwf4nZ3kreRqXK22ozelt ld36enmnvp8tn3AuS5zjfr7a6N2t0s2%2B%2BlrrsujufXvg%2FwCOPij4Z%2Fsl%2BFfg3qXhfSfFXhXw HpZ0r%2B1z4o66Xx%2FZeqf8gP8Az0r4N%2BOU3wc%2BGfxH8A6Z4b1X%2FhKvip461TSPFXij%2By9L%2FwCK X8B6Yf8Aia%2F2WNU%2Ftz%2Fica2OvbgHrxn4v8SfFTx54Gzpepf%2FAHr5PT%2By%2FwDPr0rirLx94p8d eJdK1PUtL%2Fsv%2BytTyf8AqKannv8An3%2FGv2bBY7OsblH1%2FOlkE5RUpU8%2BhL95zJNwSVpP3ZWb ja8lFq6vdfB4vJ8nwWMcMDmbSaUZLlaTu4ppq2%2FTX11uf0x%2BCdD%2FAOEm1LSvfP6enP8AkV%2Bh 3w98Of2Zpvf6H%2FPr6%2F1r5L%2FZXsf7S8E%2BFdU%2F6hZ%2Fzn6cdO31FfdcN9%2FZg9sf%2FX9etfK4njDG 8Xr63jpXjD3Vr7to21Su7bXVvuR5mH4ZwWT3fWV9Wur2dl56Ha2d9%2FTp%2BH%2BRn8Kszar%2FAJ%2Bn %2BeT2FcBNqv8Anv8A%2Fr9fQeua5vUtc5%2Bv4fz4PXrz%2Fjx%2F2osH6aWfS%2Bltdv8AgW66HlvLOZvW 93tv6Lc9RvNV%2Fp9Pz9eeeOa5u81zj8%2F8%2FT8OPbHHjmseKv8A4kZ%2Fz%2Fnn2ridY8cf%2FX7c%2FwCH 68e1fMZnxT9Tsk3fS3vddPw0Xy0EsiW7X4enl5L7j37Utc6f59%2Bo%2FHv7nuaxNY%2F4mem5%2Fr9e 3%2BHHXjivE5vGP5%2Fr%2Bf8AnA%2BvOlN44%2F4lvb9f5fzHQfjXXlXGbWzat1u1%2Bv3o5MVlV%2BnT%2FLy9 PkvQ%2BOf2i9V0vw0cf559fp%2FnjFflT42%2BI39p6l6%2F4%2F5x%2FPrX2f8Atda4NS%2Fn19M%2F4DjH8q%2FO jwfon%2FEy%2FtTUv59O34dK%2Fr7gTPf7Z4YyjHvokrt9nHrpr%2BVtj8nzTC%2FU8c1bZa%2Fh5afr8j1r wT4b4%2FtTUv6f05%2Bn8%2Ba9shsf0z9Oufp9f17VxOjz%2FwCf849fpjjPIx1sOq%2F%2FAKh%2BeMfzH419 39a9f%2FJf66r7zyjpP7J9v0%2F%2BvWJeQdv8%2Fl0wc9z9MA1mza5%2FI%2FT%2FAB%2Fw64rktS1Xn%2FHoef16 %2B3FdP1pd1%2FX%2FAG75r7wNLUp%2Bn8v07f1PqPevNZJ%2FmPUfQkfyz%2Fn86g1LVc%2F5%2Fn69M%2FTmuMfV Oe%2F4c%2Fn7%2FwD1qPrS7r%2Bv%2B3fNfeB%2BL2mwf8TL69ufbpxk%2FmK%2FXr9l3w5%2FxLdKH%2BePTqOo7%2FrX 5QabP%2FxMuvX%2FAD6YPt09u1fq%2FwDs6%2BP9M0zTfbr9f88e%2FT8PWz3CvXfrb8O3p07epyYXZ%2Bn6 s%2FQSHoPof50vnL%2FnP%2BFc3D4j0vUyf7N7%2FwCf05%2BlaVn2%2FwCBV8NZrdHpm39oHqfzP%2BFZs19z %2Bf155%2FTv68Zqz5K%2F5z%2FjWbNB%2FTn%2FAB4%2FXHt6GugCtZf2rqepaVpf%2FQU1Qf4%2F5%2Fliv6Lvgz8K 9U%2F4VvpX%2FErH%2FIL%2FAOgX9Pf8vT2r8IvgD4cHib4teFdK7%2F2pz9T0%2FwAO317V%2FX78H%2FB2l%2F8A CE6V%2Fnr%2FAIYOMcc9ua%2BCz7hj%2FWfibKsC7uOl3ra1ldPf0u2fZ5Dnq4ZyfNscrJ3stlK%2Bmq69 tt%2FLr83%2BFf2XseG8eJP%2BZo%2F5Ch%2F%2B%2BmD6Z4ya%2FgZ%2Fa61zS%2Fhl8fv2k%2FAfjXwvq2lfFTwv481j %2FhF%2FFw1XxRpOqapqml%2FGT%2FhYXgPxQP8AmX%2FGP%2FEjPhcHw94l%2FwCgRoHjL%2FmV%2FCfi6v8ATr%2BJ 0H9meCdKxn%2FiV%2F2Rz%2Fj26V%2FPr%2FwUs%2BFf7Ofjn%2FiaeJPAfhPxV4%2F%2FALL%2FAOQv%2FZel%2FwBqaXpf %2FQV1b6e3vXuZt%2Fqz4ZYGUtOZRve2vNZavXvdd773POwWJzrxAx0dW48yvbWNtNVvr6PpfzM3 Xvj9%2FwALy%2BEvhXVP%2Bgp4X0jVNU0cf9BT%2By%2F%2BQWdU%2FwA%2FSvl3xhpWl6n4k%2Fsv%2FkFaVpf%2FABNR zn059%2FxrwKb4m%2F2ZpulaXpv%2FABKtK0vj2%2F7Cg4%2Bv%2BSc%2BSXnx3%2FszTf7L%2FwCJt0%2Fp%2Fnt6%2FSv4 l4z4wxfE2PePXLo32s1fS71e2%2B%2B%2FzP6wyDhl5LgFgcC%2BWXKm3frZO%2Fy3ve%2FkfrR8GfHHhf4Z 6l%2Fan%2FQL%2Ftf%2Bn4f%2FAFzz7%2Fmb%2FwAFAv8Agox4X0zTfFWl%2FwBq%2FwDIL6f8hMZ7%2FwDMH7%2Bvbp68 %2FGHxy%2FaT1T%2FhCdV0vTdU1bSuv%2FMU%2FwCYp%2F0FMf4Y6%2Blfkd4k%2BFfjz45anpX%2FAAjf%2FE1%2F5C%2F%2F ACFNU%2Fzz6%2Fl1FfrPhfmWMWEUsxzVZFkmnNfRSWl1zK%2B6vvrraz2PzHjvKrXxivnmdWaS1tHZ Wts%2BW9%2Bnk9TpbP8Aa2%2Fay%2Fsz%2FhaHgnx63ws%2BFuqePPF%2FhTHhceFtU8Tan4n0vwuvixdM1XTc nxC2in%2B1PDQOvgL4QGFO5v8AhGCo9r8E%2FwDBSX4yf2lpWl%2FGzVP%2BE%2F0of8zbpel%2F8TT%2FAKBP 9qarpZ%2Fp2zWH8MP%2BCV%2F7UHib%2FkG%2F8InpZ1T%2FAKCmqaX0%2FwDr%2Bn%2BFfox8Df8Agjh4X8M%2BJP8A hKPj948%2F4T%2F%2FAKCnhHwv%2FwASr%2FkF%2FwDQV1T%2FAKAv%2FUveGePp3%2FdM%2FwAT4e51krwLfDsspUH7 29Ry0Tbdrpt692%2FvPx7KZcU5NjVjbyUbr3E3ZL3d1p3butb6dTv%2FABh4P0vxN4b0rx5%2FxKT%2F AMSz%2B1f%2BJXqml9%2F%2BQXqp%2FwCoL37Zr5v8VWH%2FABLf%2BJb6f8gjSxn%2By9Lz%2FwAxX8z7H9K%2FWjxV 4A8L%2FwDCN6V8L%2FBPhf8A4lOl6XpGlaXpGl4%2F4lel%2FwDIJ0vS%2FwBPx6da8K1P4A%2BKfDOmaqPE ml%2F2Vj%2FqGf8AUU0kaXzo%2FwDxUA6HpX8e4zKsFhMa%2FwCz03C7s0nytX0t02%2B7pc%2FpzIOIFjMD H6%2B7SdlZys7pK%2F8AWl%2Bvc8c%2FZ7uP7M%2FsrVOOf%2BQXpH9l%2FwDEr1TVPw%2F7ifoenSvpD4hQf8Jz pv8A0FcaXnJ%2F4lWmd%2F8AmF%2F25%2Fn8wOSm0MeBv%2BKX%2FwCYVpeP%2BJt%2FzFP7L%2F6ivP5f8JKM1zes %2BMf%2BJbqv9m6p%2FwASk%2F8AYL6%2F9gv6fjzXwWZ4VrHJrR36WWumnft%2BVu%2F1EcUrJqV1p1%2F%2B2f4n ypN8OfC%2Fif8A4pfxJ%2F3Cv%2F1c88eg6c8deS%2BIXwP0vwNpnhUf9AvVMf2vxzzn%2BYyR%2FXNex6lP %2Faf9lap%2Fhkf56c%2BteTfGvxlqg03SvDHP%2FEz1PP8A3C88Y4weevt09K6cszXOniv7Oc3ySTVm 21y8qvZPdpNu2m1utjlzHBx5ljlGOrWllrtr1u7tbn7F%2FsW%2BOP7T8N%2F2XxjS%2FT%2FOOn9a%2B6tS 1XOen9fwHY1%2BFf7K%2Fj%2F%2FAIRn%2Byu3GPp29Px%2F%2BvX64w%2BJP7T03%2FOc%2Fj%2FQ115Xmv1N%2FUH1bfo%2B r7b%2FANXPLzzCNxTWui809v66o9IvPEfb%2FPt%2F9bn6jrXl2veI%2FwCzP659uvH%2BfXNYk2uf2Z9O vc8%2B2Mc%2F5zxXhXjbxVj%2FADk%2Bv9PzzRnuaN4LS%2Fqt9WtFb799jwsLlifn00%2B%2FR%2Fcvu9DttY8c f56%2Fy6%2FTpn6ivLrz4m9%2FoM%2Fl2%2FrXgPjDxx%2F9b%2FPcfqB714VN4%2F8A%2Bop%2Fh%2Fhz25%2FEd%2FjPquOx 2923a1763tb8P6ueossSteWi39PvX6H2f%2Fwtv3%2FX%2FwCvWbrHxp0vS%2FTnp9ff%2FPP8vyy%2BIXx%2B Hhn%2FAJiv9lf55%2F8Ar%2F04rwHTfj8PE2pf8hQZ79%2F5f%2FX7Cvvcs4CzxYH6%2B1JLqrNWTS02s9%2Fm ckf7DeOUbxb7ab2S2ve%2F4H6ZeMLj%2FhOTzye3TPp%2F9fnFeXf2H%2FZnfGfx68f56Y%2FHFHwZ8RjU 9N%2Fsv8%2Bnrzn8M%2B3pXrWpaVz%2FAI9Bz%2BnT34r%2BvfDHTgzKcv2cW%2Bbo13dumzt2v5H8%2Fcd4RYPi bNLLR2cdLae7a3R6NXfy1PN4YP8APH%2BRjt2HbPa1WjNY8%2Fn9eOP17%2BnGas%2BSv%2Bc%2F4193r5%2F1 %2FwAMvuPizF8j3%2FX%2FAOtWZNY%2Fr%2BXXP0%2Bn6d66PyPf9f8A61V%2FI9%2F1%2FwDrV33fd%2F1%2Fwy%2B45zgL zSv6fX8vTnnnmuNbSuf8SQf06%2FWvYLzr%2BA%2FmK5RoOe5%2BgJ%2Flj%2BVF33f9f8MvuOg%2FCOvRfCvj jVNMH%2Be%2F5euPXJrySaD%2FADz%2FAJGO%2Fcd89rEP3f8APqa%2FVcUr2W91%2FwC3I8dPqun%2FAA5%2BovwY %2BKn9p%2B3%2Bfy%2FLNfpT4Ug%2FtPTSc4z6D%2FP9Ome1fgh8Jdd%2FszUtKz%2BQx7dfbnv%2BNftz8H%2FHGl%2F2 aeB%2BRx%2FL%2FPPrX5zxPbAq%2B2l%2B3a3r8vx1PQwn%2B2Wt02%2BW239aq1z2Oax%2FX8uufp9P071zd50%2F EfyFbc19%2FafH%2FwBf%2FwCv%2Fk9arXljzj2H%2Bf8AD9K%2BYyvPfrrtp0Wu3Trr%2Bm%2BvQ9TFYa2u1tLv p%2FX9dGe2fsf6rpemfH3wqPEn%2FIK%2FtTH%2FABNP0%2Fz9Oo5r%2B1%2FwJBpY8NaUdN7Drx34HP4nn%2BZ6 %2FwAGfg%2FVf%2BEZ8baVqnfS9U4%2FX09Pw%2FLOf7Ifhl%2B0L4D8Dfs36r8ZPG3ijSfCvgDwv4E1fx%2F4 p1fVP%2BQX4Y0rwxpf9rarqn5c%2FwBelfc8I4b%2FAIWJS0lKzavu9FbbXztr2Sb3%2BYzzE3wSitnZ O99r216W87p9uiPYv2k%2Fitpnw0%2BG2rFhjVtU0w%2FTSwOP7U1TpnPb69xX8uHxy8R6p458Sar%2F AMTT%2B1f8%2FwCR1r8zf2uv%2BC4H7UH7QviTx%2Fqnw38B%2FwDCq%2Fgt%2Fan9laWdU0v%2FAISrx5%2FZfTSx 4%2F1XH%2FCP6RrfiX%2FoXvWvz6h%2F4KW%2FGTwzqX%2FEy1TSf8%2F54%2F8A11%2BdeKvAOecdYpRcpZRk8U05 ta1JK2rt%2FN08rbs%2B84D4owXCGD5rat32u1dxf5%2F56n69a94V1T%2B0v7Lx%2FwDLX1%2Fz3rifFXw5 HhnTNV%2F4pc%2Fl3%2FH6%2FX1rxz4D%2FwDBRH4X%2FE3UtJ0rxJ%2FxKvH%2Bqarj%2Fiaf8gv%2FAKheelfq%2FqXg fVNT8N8%2F2Tqv9q%2F9wr%2By%2FwD5cf554r%2BReKPDnO%2BGm7ZVJpOym7q6TXvaffrbsftuVeI6xive 1%2FO3bXW2nrpofzkfHKx1P%2B0v7L%2Fsv%2FkKev5H%2FPPPUV9D%2Fso%2FCs%2BGf7K%2F%2FX%2BHHH9Pyr9DvG%2Fw P8L%2FANpf2p%2FZX%2FILz%2FxKOvH49v8APfnc%2BHvg7S%2FDOpH%2Bzf8AmKfz%2FX2%2F%2FV18HE55j%2F7GWQRT TdrdLO66JfrbTe57v1rA41fX3Zu1nrvok%2Btt9G%2Bv3m1o99%2FZnOm6r9P%2BJXg%2F9hT9P%2F1UXniP x54l1L%2FiW%2F8AEq64PB1Tt%2Fn%2FADz9Iaboel%2F8hTr9B9fT9fw%2FDSmsdLx6n0%2Fl79z7kV6eQ8C8 UY23%2FCrJRVvd12drq2q2stNXa%2FY%2BNzXifJcImllSb2016q2q66%2Fh5G38IPCv9mZ1TUvy5%2F8A rf545wK9I1ifS%2FE2p%2B5H%2FYK%2F4mnbr%2Fj%2FAIViabB%2FxLfp249unGB%2BZrgPHc%2BqZ6%2F2Vn%2FmL%2FTr %2FU%2Fh%2BFftiylZPkywUlzSsk3ZOT28uru%2FQ%2FPMNmzxeNTTaV72u0tWmu66r7tzy%2F4weDtK1P8A 4lft%2FwAhfTP8%2FwDE4%2FzzmvkrxV8JNL0z%2B1dLzj%2FoF%2F8AE0%2FAfp7dPwr7qmvevXVR%2BP19f59%2F XpXhXjz%2FAJBf5%2FyNfiXGOVYRf7alZ2tZd3bdL9ex%2Bn5Bn%2BNdsDdPVNt66aaelum%2Fqfn1qWla p%2Fn69u%2Fvxnr615L8VNK%2FtLw3pX%2FUL1T0%2Fnz1OPWvofX%2FAO1f7T4%2FyOMf1ry74nAnTdKOm%2F8A Eq%2F4mnXVPp2%2Frn%2FGvg8MnhMZlT1s93q97O7%2FAOC%2B%2Bx%2BrxxScVpFqy7tbLy9DN%2BGN9%2FZmP5j6 %2FwCe%2Bfr1r9TdB1zHhvST%2FwBQv6dj9Ow78%2FhX5Zab%2FwASvTf%2BYT%2Fnjt7e34CvqvTPH%2F8AZnhv Sv8AOf5fhXN9Vcse2k3r01e67K2mn%2BdjtxKTwcE%2B36RPpD%2FhKs%2F2rpepc%2F0P%2BT%2BHX6fJfjzx x%2FZmpat1%2FwCoV%2Bn%2Bfz61Yn8cf2npp1TTR%2BvGeP8AJ6%2FpXyr428f6XqZ1XqP%2FANf198f%2FAFji vqMHkGOxrV07XXn2301t9%2BvmeDfBYJJtrVd%2FL7nf8%2FI5Lxh8Rv7T%2FtX%2FACB%2F%2Brt247YGfl34 kfFr%2FhGfDYI%2FT9exrE%2BNnxG%2FszTf7L6%2F1%2FyPX1Ffn14k1zVPE3p%2FnJ%2FQ%2B3pX7vwZ4dYPFcmO x8dmnqmtE4r16bf8MfnHE%2FGH1RP%2Bz93pZebt0dtNeyMzxJ8TdU8Tal7%2FAF%2FD6%2BmfXH5dL4V8 R46d%2BPb9cn%2Blc3pvgf8A%2Bt2%2F%2BsePTjt0rrdN8H6ppnv%2FAJ6ehI79f0r9%2BxSyJYB5elDSNtlf 4Va728lptZ3sfmWVvPJY9Y%2BTdm03q9m18vT7%2Bx%2Bpv7LviP8AswaVj%2FOen%2BepOPWv0ymg%2FwA%2F T9fwz%2FgPx8%2BCeq%2F2Z%2FZWP88e%2FwDn271%2Br%2Bg339p%2BG9K%2FH6jnB%2FDr%2FOvzTw9xX1PO84wGtuZ8 q6WT0079X%2BaPrfE3CJ4DKMfvJqPNtfVRWr3%2B%2FrqVryD%2FAD9f8f19uaw5vu%2F59RXS3nX8B%2FMV yN50%2FEfyFfrp%2BNleafj%2FAD%2FL1P19zgVmzT8%2F5%2Fl6D6%2B5yaJup%2Bo%2FlVCg5xs33v8APoK5R5ue 3T0P9K6Gfv8A8Drnn6j6f1NB0H4malB%2FZmPp0%2Fz1%2Fpxx3rkoZ%2F8AP0%2FX8cf4j9DvEn7K%2FijU 9Szjsen%2BcdPevbPhL%2Bw%2Fpf8AaX9qeJPf057c%2Frz%2BvSv0zPs9wWCV12fpqulvPa3%2FAA%2FiYTCt 2%2BST%2FX8t%2FwDgnxh8K%2Fhxqep%2F8TT6%2FwD6j3Hbtge9fpl8K%2FCv9mdzz9fz%2FwD1%2B9fTNn8HfC%2Fh jTT0%2FwD1fz54rNh%2FsvTB%2FwAS3%2FPH%2FwCv69ga%2FCM1z3HcS436jgU%2BXXW1utt7ddt%2FU%2BnwuH%2Bp bdu%2Flfyd0%2Fu%2B46TTYM%2Fj09x%2Bv6kVZ1Kf%2FwCufz%2F%2Bt0%2BvtRDfd%2Fx4%2FDr%2FAF%2FDPpVaa%2B0v8SOn frz%2BY%2F8Ar9q9PK8reD0e%2Bzt0enf59e6T78uJxLxlkrrp0vp579F2M2GA6n29z%2FzCfz9%2F8%2B9f r14b0P8A4WZ%2FwSF%2Fa88L6l%2Fa2q6T%2FwAIx4u8K%2BF%2F7L1Q6VnVNL%2FsnxZpeqf2qdD%2FAOJx%2FwAT zS9L61%2BUGjwDxN4k0rS9Nz%2FxNNU%2F7hmc%2Fn%2FYvr%2BXWv3L%2FYz8R6X4m%2FY5%2BNPgPTT%2FAMgvVP7V 1Tp%2FxNNL8UeF%2FwDkKf8AlL1Qfr3r9O4Gw31zOHr%2BerSjZO3n8nrpY%2BYzzE%2FVMJFWb95K1rvV pNtWvbzP89DR5%2FHnwM1LxV%2FaWqf8SnxR%2FZH%2FABKDqg%2F4mn%2FE0%2FtbS9U%2Fsr%2FPrXgH%2FFUan4k%2F 5i2q%2FpyP8%2F8A6ia%2FTP8Aav8A2bNLHxI8Vf8ACE5%2F5Cn%2FABK9I%2F5hfGqf8gvSvT2%2FyK%2BeNB%2BA GqDUv%2BJl%2FwASr%2FoKev8A%2Bv0x%2FwDq9jGLHc31Bx2k3ZrpfbVdtL3PQwlnDuuVafO%2Bp0n7JfwB 8eeOfi14V1TUtL%2FsrStM1Q6qdXHT%2FiV%2B%2FXp%2F%2Bqv7D%2FDeq%2F2Z4J0rS%2F7U%2FtX%2By%2B%2F4n%2FP%2BJr8j v2Y%2FgP8A2Zpv%2FCUf8SnSuNY%2F4lH9qcn%2By%2F7JGqZ0vrq4yc%2F5zX3nDP3%2FALU1b%2FkKaR%2FxKNM0 v%2FqFgY7%2FAPEl79%2B30r8248ynGSj8Katrpfot3b0%2B5a9u7KsW01q0r9Py0%2FXy0Ot8beI%2BNV1T %2By9W0rSuv%2FMM%2FwCgX%2FyFP%2BQ5%2FT6CuJ8B65pep%2F8AE003VP0%2FA%2Fjzx7%2FhWbrF9%2Faem%2F8AEt0v %2FoMf8hTVMn%2FI%2FT14ycSz1XS%2FA2m%2F8hTvg4%2F5hZx%2BvJr%2BYP8AVVf25dxTW%2BsVazt%2BN0vI%2FWML mq%2Bo2TtpbXorf1dd7H1F%2FwAJj%2Fu%2F5%2FGs3%2FhMf%2Bgb%2FwDevj%2FH%2FwCvXheg32l%2BOf8AkGj89U%2Fs r%2B1P04PoT%2BXaukg%2F4pnn%2FI%2Fl%2Fh6d6%2FRcLhVgdErdNPT5apq3lax8e2223fdvV33PpjQNc%2F8A 14%2BvfH07%2Bo9q6T7dz%2FxMv%2BYp09%2F689Pw79%2Fm%2FwAH%2BMdU1PP9pf59v8Otetf8JHpfp%2Bo%2Fwpv%2F AG3fp362%2Fr%2BuqNvUp8fh19j%2Bn6A14D4qsf7T%2FTH5j%2Bf9PwrtrzxH%2Faf%2FACDuuc459M%2F8gv8A Tpwf1838Va5%2FZn%2FIS%2F8A1fy79vwr4LinIfribeiSb7LS9tdn09evQ%2BgyHFvCSWt3e1%2Bt9NFr 0ufPGsaV%2FwAIz%2FyEv7Jx%2FTp%2Bn%2BfWvjD4keMf7T8Sc%2F8AML%2FH8cgenAH%2BHPsfxm%2BJn9me%2Bq6p %2BHv7e3P4V8YWf%2FQUzjP%2Be%2FP%2FAOr6V%2BOPLLPWOz00%2FE%2Fd8hba11v3835nusN9%2FwAU39D%2BfbnH Q%2F8A16NY%2BIx0zwT%2FAGXjp3zxpfcnt%2Borkpp%2F7M03%2ByyevPT8ev8An27V20Oh6X%2FZv%2FEy5x2%2F njjn%2BfvXg4bEvJ8ddrmXS6ur6W307W%2BXU%2FRctyv67gu3fbTRfPd%2Ff%2BPzND8RvHnhnTRpY%2Ftb VtKP9Pp%2F9evmbXvEfxQ%2FtLVSdL1b%2Byj%2FAI8Y5%2FXj3r9MvsWl%2FwDQLP5n%2FGs3UtC0vU%2F%2BYV1%2F TH%2BTX3mVeIawXL%2FwkK%2BmrWqty%2B9%2Fw99DwcX4dPGPXNnr0%2B52Xpe2i8lsfkdN4A8UeOdS%2FwCJ l9Of8%2Fh9M5xXf6P8CP7M4%2FP%2FACBnjt%2FLuPvy88OaX%2F0C%2FwDHHbg8%2BmPTv3rEmsdL0z8cZPpn 8vX8K%2BmxPivnGMSjgUoq1rWS6R00S8tbfg7HmYbwwybB649uTT6663Xe%2FwDS%2BR8l%2FwDCuf7M %2FwAnOO3%2BJz%2BNZs3hz%2FHB%2Fl%2Fh%2BOfWvqqb7v8An1FcVeaHz%2Bf%2Bfr%2BPHtjjDCcY4%2BT%2FANubbv0v fp893a%2Bu504rhbAx%2FwBxWiS3j0SWz9dvloeOab%2FxLO%2F68Z9M9fwr9evhXP8A2n4J0r%2FOfp7%2F AIc9K%2FMSbQ%2F6fz%2Fz%2FnmvpD4J%2FEbVPDP%2FABK9S%2F5BQ9e%2F6ZP0z9OK%2Bn4f4nweU50sfjW1zP5O 7ju%2F636HwnGXB%2BNzjJV9RT93W3VJWb7LyS%2B5H2xNBx%2Fn%2BfqPp7HIrEmg%2FwA8f5Oe%2FY98d%2Bkh n%2FtP%2FiaabgfT1%2Fr2%2FwA81Wm6H6D%2Bdf0VhMXHHpSi000paNWStpZ6%2FwDB3P5qlg5U24z5otaP mST0062OJm0r6%2Fnzx79PXB79Kr%2FYR7%2FrXWTQc%2F5%2Fn6H6exwaxJoOv%2BH5j%2Bo%2FMHtWxmc3eQf0 %2Fp3x%2BOMemfSuee3%2BY8D8h%2FU%2F%2FWrobzv%2FAMBrAbqfqf50Ac%2FrHj%2FS9M%2FX8MdfXPpx%2BVaWg%2FGL VB%2FyDdL9OP8AP1A68DnpXm95faXqft%2Fn6fQ%2FSus8Nz6Wf8%2F%2FAK%2FT3%2FwzzTEt4Lu2nvfy8tvX t2KwuG%2Fr57devrq%2Bx6Be%2BMvFGp%2Fz%2Bv8A9br6j8a0tH%2FtXt68fTj%2FAOtS%2Bdpf%2Bcf4VYs5%2FwDP 0%2Fw%2FT34r43CZm8FJNRt1u1Z6tdbf8H8EdX1f%2Br%2F%2FAGx0kMH%2BeP8AIx27Dtnta8j3%2FX%2F61aOm z5%2Fz0%2FzjsT%2BfNbf2b2%2Fz%2FwB9V9RhcX9bs30s%2Fnv2vbX%2BtDjtbpb%2Bv%2BGKug%2F8Sz%2FsKapperj%2F AD9Nc%2FpnnFe7fBn47%2BPPhB438Vf8I3qh%2FwCEV8UaXq%2BleKNI1T%2FkFappfhfS9W%2Fsvpjnj%2Fyr 6%2BeleOXvT8NH%2FwDTXWJ53%2FEy%2FtTrz36%2F8TT9O3qPc16uFzTGYBrH4GTik1110erS9F%2BXoc2L wixqtZd7WT32%2BR7r%2B0t%2Byh8UPi%2F4J8KfGT9m%2FS9K8VaVx%2FwlGkappel%2F2p%2Fwk%2F8AzFP%2BYH2%2F %2Bv71%2BGk3iP4yaZ4k%2FwCED1L4X%2F2r%2FwATT%2FkEanpeqddUH%2FE0%2FwCJoP8AioPz%2FLrX9Q%2F%2FAATZ %2BI2qaZ4k8VeA9S%2F4mvhXxRpf%2FE00gevH%2FE0%2FnX0R%2B0V%2Bx3pWp%2BJD488N6XnStU%2F4mp%2F4lX%2FE 00v%2FAKimlf8A6%2F5cftmRYnAcYYFPB5qlnUbcylZbKN0726p3%2B%2FofH4pY7J31s9F6N9X6ed%2Fm fzbfBP4%2B%2BKPDJ0rS9S8B%2BLNL0r%2FkK%2F8AE0%2F5Bf8AxKx%2Fa3%2FIU6HRef8ACvr3Xvj98L9T03%2Fk qH9lf2ppf9q%2F8TT%2FAIlX%2FcL%2FALU%2FsPj6Zx%2FxN%2BOlfSHxm8AZ%2FsrS9N0v%2FiVD%2FiVf9wv%2By%2F8A oF9c9u%2F8q%2BHvEn7Oeq6npv8AZem%2BF%2F7K%2FwC4WdK0vP8AyFfz49vyrwuJoN%2F7ByOTW7S5k33v 3fR3%2B7p6WVyWjckm3fVry7%2BqMzxV%2B018L%2FA3%2FM0aTqv9qf8AEq%2F4leqf2rjH%2FEo%2Fsv1%2F5DmO o9BXxj48%2BMXxR%2BL%2Bpf8AFE6Xq%2FX%2FAIler6p%2FamqjVO%2F9l6tpX%2F1uo%2BufrTw3%2Byv4X0z%2FAJCX 9k%2FTr%2Fhxn1%2FMV794V8AeA%2FDOpf8AEt%2F4mp7DS9L%2FAOgpzg9P89PSvxvE5U%2Fr3%2FIp3sua1u1n srf5rvY%2BzwuLtpfTe1%2FPz87b9fuK3wN8K%2BPPDPgnStU8SY%2F4mn4%2F2Wev9l%2F5%2BvFe66Dff2nq X1%2Fw9Oev613%2Bm%2BB9U1TTf7L%2FAOQXpXX%2ByMf5A%2BtdtoPw5%2Fsz%2FmF%2F59vwH%2Bc1y4rg7GvZddFf o7O39eSD%2B0%2F734mbZ6H%2FAGl%2BPH4f59fTFaU1jpemf%2Fr7%2FwCP078D22%2FFWq6Xpn%2FIN%2F5hX8v8 %2FT2z0r5v8VfEbVNTx%2FwjX9r%2B%2Br4%2F4lfYfz%2Fzjr5eLyvB5Km8c%2BzTs93bf8NF%2BGp1YT67jUrW W3W%2Bn3dE%2FTVHf%2BI%2FFX9mAc9x6f8AIL%2BvOfX%2FAOvX50fGz9ozrpfgn%2Fia6r1%2F6hel%2FwCTn%2Ble keNvDnijxMP%2BKk1X%2FwAFf%2FEq%2FoPUdeccV8l%2BJND0vTP%2BQaf%2BJqP0%2Bv6%2F4V%2BIcY8Yx1wMWumq a8krW2urfL0P2Tg3g5u2Px7urKy3u9OnXU8cm%2F4SjxNqX9qal%2Fj27%2FT39fetKeD%2BzOn8%2FwBD 7fnnNaU2h%2F8AUU9Af1OOv4%2F5xXN6xP8A2Zpo%2FtL%2BXH8vy6%2FSvzr619ddlv8A1%2FWz9dT9RS%2Bp pW%2BHRX%2BX5W%2B%2F03s6lrn%2FABLv5%2Fr%2Bf6%2BntXrR1X%2FkFe3px%2Fn6%2BoxivlTUr7%2FiW544znp%2Bn58%2F 5z6R4b1X%2FDn%2FAD%2BY%2BnNeXmeWbO3bdfPSy9d%2FvPschxTt5Pft0te36fPsekXmq%2F4%2F5H8vw4qr %2Fan%2B9%2BX%2FANesWa%2B7fX%2FJ%2Frx%2FSsS8vuM%2B4%2Fz%2FAIfpXlrCvpHy2%2FXl80e%2F9a8n%2FwCS%2FwCRt6lq vQ%2Fy%2FDqf6%2FWuI%2B3f2Z6%2Fj9P5%2BnX1qveX2fp%2Fj%2Fnnt1z15xPt39p%2Bn4%2FX%2BXp09a9TC5ZbXbz2 87r8F93ocn1m%2FW%2Fzv6faO2mg6%2F4fmP6j8we1Yk3Q%2FQfzos9V%2Fsz0%2FwDrZz%2BP%2Bfx0fO0v%2FOP8 K6uV4To2%2FTTy36%2F1ub6Pt%2BHl%2FwAD8DFmg%2Fpz%2Fjx%2BuPb0NFnB%2FX%2BvfH44x649Kzpup%2Bo%2FlWjo 8%2FX8v58f%2FW%2FWuvE3eCha92tG%2B7UbHkaLfb7tD374e%2BONU8Mn%2FiYj%2FPPHf8q%2BmYb46n6DH%2BfX 34PX6V8TzWH%2FAEDeh6df8On5ete6%2FDHXDqem%2FwBl5%2F5Befx%2Fw4%2Fz6fovhPxlLCY5ZHj79lJv f4WtW3buvuPwzxX4OjisG88y%2BKjazaStqmr6LbdnrfnH3%2FIVVmn%2FAM%2FT9Pxx%2FiM2af8Az9f1 %2FHH%2BJrTT%2FwCef8nPfue%2BO%2F8ATW5%2FOW2%2B%2FUzdT%2Fh%2Fz6VxT9R9P6mukvOv4D%2BYri36j6f1NAHj OpWPT3%2FDtjj8%2B39a29H%2FAMf%2FAGaq019x%2Bf045%2FXv6cZrS0zofqf5Vniev9fygeo6bP8Ap%2Bn5 dP1%2FSvSNHg%2FHj9P8%2BnPPvx5do8H%2Bf849frnnHIx7roNjj%2FPt%2Bf8A9b2rwMVhVvpr6a6L18rb 6eZ6CezXqjpNNg%2FX9fy6%2Fp%2BtdLD1H1P8qzPs3t%2Fn%2FvqtOHqPqf5V14XDW8vw%2Bbt%2Bj%2FRGeKxP Rfd%2BFvws7eS7ISaD%2FPH%2BTnv2PfHfmpuh%2Bg%2FnW7N97%2FPoKwrzp%2BI%2FkK6PLp2%2Fr0Rxn3n%2FAME%2F LH%2Fi5Oq9OM9MZ%2FT%2FAD61%2FS54avv%2BJb%2Fh9D6f5xnFfzW%2F8E35%2FwDi5Gqn9Rj%2Bf%2BAzmv6SbOD%2F AIlv9ef%2FAK348ce9fV8AtxxuaNXTUovTR2Um%2BnSx5ufpPA9L3tft73%2BR1v2HS9T%2FAOYZpP8A 4K%2FXn3xjGe9fPHxa%2BFel%2BJ9NP%2FEr7Y0v%2By%2Ff06dv8Oa9shvufy%2BvHP69vTnFE0%2FH%2Bf5ep%2Bvu cCv6SyuvCSXPGLVkr8qeltvu7%2Fdufk%2BJoSTTTd097vvdaL73b%2FJn4w%2FEP9jvS9T%2FAOJp0%2F6h H9l%2B3%2Bf8M15LD8D%2FAPhGeml%2F8gvr06%2B%2F6%2FjzX7YaxY%2F2p%2BH%2BOfT%2FADz%2BPm8Oh6X0%2Fsvn%2FP4%2F T1x0rzs04YyXGO%2BCSvpJ%2BT0vvZ2ut191z3MJnuNiksbtolr003%2B5Py8j8xIPBv8AZmmn%2FkLd D%2FxKDpf%2Bf68c966T%2FhB%2FFGp6b%2Fah0saVqv8AyCu3b9ccf5zX2h4kn0v%2FAJBf%2Fgr%2FAK%2F5x9K8 tvNc%2Fsw%2FXA5x%2FwAwv8evT%2F8AXyPgszwuDwWyu1fbXtZ6eb7%2FACPfwmKeMat5Wvs9vwvY%2BOZf hJpWp6l%2FZfiTVP8Aiaj%2FAImuemln0%2Fz3964nWPhXpWmf8wv8O35j%2FPHWvvObQv8AoJen9q6X 7%2Fz9f%2F19R5L4q1z%2BzNS1X%2FoK5P8ALk9s%2BntX43xl9ReBf1277bN9LX%2BVr%2Bfkfd5D9d%2Buq9rW %2FwCGv0vfb%2FOx%2BePjb4ZHU%2B2f%2B4p%2FZf8AnoK%2BFfG3w5%2F4mR%2F4mmNKz%2FzC%2B%2F8ATpx%2F%2Buv1E%2BJG q%2F2npv8Aampf8Sr%2FAKCmkaX7%2FwDMU%2Fl3%2FDsPzo%2BJ2q6rpn%2FEs1LVPc%2F54%2F8A1%2FhX8NcZYXB%2F Xn9Qcr3%2Bd9Pn59l01P6W4OxWN%2BpJN6aX6aK2y17f5nzf4ksdL0z%2FAOtqnX6evYDr%2BVfIPjbV f7T1M%2Fjxz%2Fnv%2FPFet%2FFTxhpf%2FIL03Vc%2F%2FXyf89OnbivnjTf%2BJnqX%2Bf5D65%2FX2rp4Yyt4OP17 HN2a0Tu%2B1lsrP%2Btj6nEYpNrA9dHzW06dfmbc2lf2npuP05%2FL%2FP8AjXpGj6V%2FZnhvv%2FxK%2FwDP QHqcY%2FlVnw34c%2FtP8%2Bemc%2B%2FoP6cV7HNY6Xpnhv8A4mX%2FABKu2f7L6c857Yx%2FjjmvNzzPVzxw Ed3JW1V3rFJflZJd9T7DK8LZK%2BmiX4bXfy2%2B7Y8lvIP7U03%2B1NN%2FE49v8fz6da83mvv0%2FLrj 6fT9O9db4P8AEf8AxUmraXx%2FZWq%2F59j9Tj6VpfE7wd11TTT9ePw9f89q6MHiVhMasDjkrNRt 135Wru2u6W9rrayPW%2BrLF4K6dnH18nbf0076enm8193%2FAB5%2FHp%2FT8celSVy8M%2F8AXj%2FDn9M%2B %2FqK6Sy%2F%2BJ%2FpX1OJwyVpK1tH66XX4eunmeVh9HZ7%2FAOXMVvtw9%2F1om1X6%2Flzz7dPXA7dazdSs ep9Pwz35%2FwDr%2FwA64ma%2B%2FszPX%2BX%2Bfb%2BldGFwixiV7aW3V29r%2FPb5nm4rM3g2lrvrvpdpa%2F5N f5npE0%2F%2Bfr%2Bv44%2FxNbQb3GpdTxzz%2FT09u%2FvXE2c%2BqZ%2Fzjn%2FP8uvfS0i%2B%2FwCJln%2BY%2Fl%2Bf0HWn %2FZmm%2FovTbqeTic0eluuu%2Fpb%2FAOS%2FHzPfodV%2F%2FUPzxj%2BY%2FGu28E%2BJP%2BKk%2Bn58%2FTj%2Bf4V83f24 PUfma09G1zp%2Fj9OR%2FwDX%2FLrXhrLMdgJPMY6yTcklv7ttlur2t%2FwBPE4PHweX43W6aWml5WWv 4d%2Fmkkfpj9hPt%2BlV5rH9fy65%2Bn0%2FTvVb4e65%2FwAJN4J7%2Fjx146%2BlWpvvf59BX9FcCcYLiTJe Vv8A4Wo6Wemia6eib2e2x%2FMPGXDH%2BrWdPCJtxm209be95rT7n19DmtSgz%2Fnp%2FnHcH8%2BK4B%2Fv H8P5Cu%2FvOn4j%2BQrjWg54x%2BIH9TmvuleyvvbX1Pijxj7H7f8Aj1dJpuldOP0%2Bh5%2Fz7%2B1ZkPQf Q%2Fzr0DQZ%2Bf6%2F%2FXz%2BHTP48124nr%2FX8oHSaPpX6H6%2Fj9Pf6%2BvHtmjwf5%2Fzj1%2BueccjHN6PB9eP 84579Ov58HPWWfT8T%2FI15YGvUv2g%2Bo%2FMf4VFRQBHNP1%2Fx%2FM%2F0H5Ad65u8n%2Fp%2FTtn8M59M%2Btb U33f8%2BorFvO%2F%2FAa6APrT9gjVf7M%2BP2lf8TT%2FAJCf%2Bf0z69%2Fz%2Fqa02%2B%2F4ln5%2FTv8A5OPf3r%2BX f9gnw3%2Fafxs0vVNN%2FwCYX%2Fnk%2FwCffPf%2BnbQZ%2FwDiW6V39uo%2FLgV9pwL%2FAL7Hu7389Fv3%2BZ4m ef7ivWP%2FALadJWdN1P1H8q0fP9v0%2FwDr1Wm6n6j%2BVfvGG6f1%2FMfnRzeo9D9P6V45rH%2BH%2Fste x6lPn8evuP1%2FQCvLryD%2FAD9P8P09%2Ba6cTolbTTp6oa3XqvzPm%2FxLDqnf%2FPTP9Of0o0fSv7T1 MaXqWl8%2F56%2F5OSK9R1LSv%2BJl3z%2BZ49%2B%2F%2FwCqubn%2FAB6dv%2BQp0%2F5hPt61%2BYZps%2F6%2BzE%2Buwm0P SP5RPLr2f%2BzNS0rj%2FiVf5%2F8Ar56V4V4w%2FwCJnj%2BzeNKP%2FwCv34%2Fz64%2Bh5p%2F%2BEn%2F5CX%2FMLH%2FE r1fj%2FkKdP%2BJr%2Fn26V4n4wsf7M%2F5Bo%2FPtg9Pf8fzNfnPEGWYLGYBvsne%2Fdf1%2Fwdj7TKsVrG61 dt%2Bt7fh%2BLPgz4qar%2FZv%2FAEFv%2B4pnt9Op9uvpX5d%2FFXXP%2BQqNS68Z%2FDj%2FAD2%2FLj9MvjNP%2FZh1 X%2FmKn1GfX9cc9s1%2BVHxO1XGm6rpf9l45%2FwCgp%2Bv6%2FTn1r%2BEeMMKlxTppG9nbbePbqtet%2B%2FZ%2F 0pwd%2FuK9H%2F7Yfn54kvv7T1I5%2FwA8%2FX8un0rtfB9j06c%2F4fy%2FTFc5qcH9mal%2Fnj%2FPp9T0r6Z%2B D%2Fw%2F%2FtP%2FADx29%2Box0yK9vPc0wWByRLyVl12jb%2Btl9zPs8swz%2Bu3bb27NdNL7f0ulz0b4e6H6 %2B%2Ff%2FAOv6%2FmPU113xsvv%2BEZ8E%2Fr%2F9f8%2Fwr6H0HwPpemab%2FwBQrt2%2Fp0zx%2BfPavjD9q%2FxV%2FwAS 3%2By9N%2FsnH%2Bfx%2Box7H1r8eyr%2FAIWeKMp35b3d9raN7%2BXfz2PqPrVk7J6Ly7XX6HyX4P1X%2FP6f L%2Fh%2BFfXugT%2F8JN4bOl6l09O3v%2BH4e5FfD3gmf%2BnA%2FLn9O%2Ft6mvof4YeKv7M8Se%2FGMj%2FP%2Bce4 r9E4vyxpqWB1a5G7eVtL28m9PJLoPIszu3HXtrt2%2FrzPLfFWlf2ZqX%2F6uOcj%2FwDV0%2FI1Xs5%2F 8%2F8A1uuB9ccd%2B%2Fv3xg8Of8xTTf8AP1479sV8qQz%2FAPEyz6f5%2FM%2FiT6DivUyHFPOMCk7qyW72 slpr%2FwAG1up05m1hMYmldWu30XNbytfv%2Fmeo%2BR%2Faem54%2FL9c9vb%2BRrxzWP8AiWaln%2FP%2BePx%2F GvUdNvuvt%2BPfPP5d%2FwClcl48sf8AmKds%2FTP16f5Hp09TLHbG%2FUW3ZX1e3Trtd9Pv8zwc9ing vry1e1kr9L6Jet9rL8TEhg%2Fz9f1%2FDP8AgSzm%2Fsz357%2F49v8AP4WdBg%2Fzj68H%2BXPsCehrktYv sfy%2Fn%2BXQeg619RhcK8ZjfqST01v06b2f%2FDnxmKxX%2BxLXWzt31t6v069uxo%2F2t7%2Fr%2FwDWrT0f Vf0H1%2FD6%2B319eOA%2FtD2%2FSuks%2FwDiZ%2F2V%2Bn%2BRj26f0rpxmEsmmtLNWey8v669LHNhMX1vdq2v z0f9W6dD9F%2FgDrn9l%2F5B9PX%2FAOtivpDWJ%2F8AP%2Bc%2Bn0xxng5%2BOfhv%2FwAgz%2FgdfY3%2FADDNJ%2Bp%2F 9mr4%2FwAMM0eC40zbAbLmvHXs07J6JN7t%2Buhy%2BLGV%2FXOGMpzBW5ktWlra636ro9XpZHAXnf8A 4DWPXQ6lPj%2FPX%2FOe5H581x8t%2FwDOenQdcf1r%2Bpk7pPurn8znj9n0%2FE%2FyNd%2FoX%2BH9K5Kz0rP6 f5z%2Bp44PPau202x6H1%2FHHfj%2FAOt%2FOu3E9f6%2FlA9a02fH4dPYfp%2BoNdbDP%2FXj%2FDn9M%2B%2FqK5LR 4Ppz%2FnHPbp1%2FPk47aGDj%2FP8AP1P09hgVxgT1Yp8MH%2Bfr%2Bv4Z%2FwADdoAz6x7zv%2FwGukn7%2FwDA 65u87%2F8AAa9D0A%2FSD%2Fgl3pWl6n8WtVz0Gl8c%2FwCev5V%2FQDpp%2Fsz%2FAIlf%2FQLH%2Bc9fT14H0r8G f%2BCTt9%2FxdrxVpg7aX%2FPv9On41%2B%2FHiSx%2FszUv%2Bwp%2Fnr6dM%2B9fScHf77H%2FABL8zxM8%2FwBxXrH%2F ANtLMN93%2FHj8Ov8AX8M%2BlaU0%2FwDnj%2FIx37Dvnthw%2Fd%2Fz6mrX2n3%2FAM%2F981%2B74XaPovykfBFa 86D6H%2BRrm9Sgx%2Fnr%2FnPcD8uK25p%2F88%2F5Oe%2Fc98d%2BS1Hqfr%2FWniev9fygc3qfQfUfyrxzX589 dL%2F5BeMZ%2FwCop%2FL8Pxr0iaf%2FANzH%2BeP88e3Pm%2FjDOmab%2FwAS38ex79v856V%2Bc5ps%2FwCvsxPq Ms%2B1%2FXc4DXtcH9m%2F2Xpuefw7%2FwDMKGOe%2FH06V8veMPEf9p%2F2r%2FxNOf8AmF9c%2Bp%2Fsrjj6%2FwCR 7F4qvv8AiWn8%2Fb9fr%2BdfN%2FjCf%2FiW%2Fn%2FxN%2B56dc9v6V%2BXcQYr%2FYGvJ6ddvP06r53PtMJ8SX95 fkfIXxUP9p5%2Flj6foPXpX5v%2FABgsevv%2BPbPPr%2BPbNfoL48vvf14%2FLr%2FXJ9M18qXngf8A4SbU vp%2BeAMjt%2FwDrFfw5xTi3%2FaDd9VJ9r3vtq93%2FAMMf0Twa1ZXenIvyjffQ%2BDPB%2FgD%2FAISbxJ1z %2FwATT6fy6%2Fy%2Fp%2Bpvw9%2BFY0zTdK9sjnp7f54%2BtaXwl%2BCGl6ZqWP7L4xxz9eR%2FnNfSEuh%2F2Zzp pP8An69sD69utfBZnicbnCV01FJd9LcvS2v3226H2eKz7BYNrA4Fq70u7buydvx8n3e54D42 vv8AhGdNz%2Bf6%2FwDMM9fx7dsV%2BOfxyvv%2BEm8Sf5%2FP%2FwCv75x6%2Fp38ctV1T%2FiaaV%2BX8%2Bn49R6f hX5m%2BKtK7%2Fz%2FAEz%2FACz%2Blelwdhlgsb9dbsl0vZra3ov89z0sJd4Jb3dt99jy7QbH%2BzOv6dev P4c0aZff2Z4k0rnH4ew7f%2FX6%2BnSuts7H%2Bv8An%2FH9e9cTrFj%2FAMVJpQ9f8f8A6%2FHYHpX6fh8U sapJ20i1rr01%2BV7dS4%2F7G426tfLX%2BvT8vqvUoP7T03P8%2BM%2F5%2FD9K%2BXdesf7M1L8P6%2F8A1%2Fbk fl9a%2BG%2F%2BJnpuM9uf%2FwBZ%2Fkfxr5u%2BIVj%2FAMTHt29P8%2FT9OK%2BR4ZxVse8Bbrvt17qyW679z6XM XfCRd7%2Bd%2FT9Dm7O%2Bz9f8f88d%2FTrz201j%2FwAJN4b1U%2BnPt7ce%2FTGefxNeXQdv%2BAV3%2FhXVf19e evftx719jmWGcZKUdJJp3vZ6NO9%2Flpb79jwsNiU1yvZq1nbqrabr81t1OJs%2F%2BJZp2q6p%2BXfH %2BGf6%2B1eAzX3%2FABMfwP05%2FTHrjj1r3X4td9L%2FAD%2Fpwf6%2Fh2rxOz0r%2FA%2F%2FAKv5fl6Gvu%2BGP9y%2B vPdWWr1vpbV69F%2FwNz8xz27x31FXWu6v1a32%2FwCBr1M2H%2B1NT1Icf%2Fqx249f8fevdfB%2Bh9P8 55%2Fz1xz7Vm6bpWP8%2FwAvTrj68V6jo8H48fp%2Fn0559%2BOTPszTTS7W6W1Vvm9tj1MqyuzTd9Gv u0t%2F27tZHtnhDVRpn%2Bevf36%2F59%2FsbwTff2l4bH%2F6vX%2Befzz%2BHxP4V1X%2FAJhWPTBz%2Fn8Pwz3N fUXw3n%2F5Cul%2F%2FW%2FwHH9Pwr8x4Y%2F2PjbKXZrmavvv1u%2Br9fPqz0uMX9b4XzZX%2BFW%2BStt16LZa 38zb1iD%2FAD%2FnPp9c844OeBfqPp%2FU11mvT8f1%2FwDr5%2FDpj8Oa41r75j1%2FX%2FP581%2FYuHd4t97P 70fyVsUoO%2F4%2F0rv9Hg%2Fz%2FnPp9Mc44GSivQA7%2FTYP0%2FT8un6%2FpXRUUV54FitCiigCjN93%2FPqK xbzv%2FwABoooA%2FQb%2FAIJg6r%2FZnx965%2FtTSz059OPb%2FPNf0oeJIP7T03r3749fXp07f4Yoor7X g%2F4oesf0PDz7r8%2F%2FAG05Kz6fif5Gkoor92yzVQv2X5HweJ6%2FP%2F24gm6H6D%2BdclrPf%2FP96iiu fFbr1%2FRGEd16r8zy7V9V0vTPX%2Bf%2BPr7d%2B9eb%2BML46n%2FyDv19%2Bvr39vfrRRXwOK1Sv2%2FU%2Bvwf %2FLv%2FALc%2F9sPAfEkH4%2Fme3sB%2Fkfn8zfEjVv7M46%2Fj6dsdv60UV%2BYcWJUsC1DRNNO%2BuyX%2Bf4I%2B wyn%2FAHz%2FAMA06fFE%2BHtesf7T1L6%2F4evPX9a9I8B%2BB%2F8AOc%2Fp0H8hRRX8WZnl2Fq54ueDd3rr %2FNJX6f1r3P2LDY%2FE0sEuSaWttul159tPTQ%2Bh7PQxpn%2FIN9scdT%2Buev8AXmvN%2FGF916c%2F4fy%2F TFFFdPFGU4LL8BfC03TfKne6eyXkh5TVnVzCKm7%2B8lp2vF%2Fn%2FVj83%2Fi1qv8AxMtVPP8AT8PX 6cd6%2BVNYsc%2Fz%2Fn%2BfUeo60UV%2BZZS3dK%2Bltvmj95wnw%2F8Abq%2FM5Kzg%2FwA%2FX%2FH9fbivNvGFj%2FxM iP8A6%2FX19vr%2BPaiivuMr%2FwB6l6R%2FNFYjePy%2F9KR7t4J1X%2FiW9vw%2FHt2%2FxxXifxIvs6l%2BH%2F1%2F pj8cUUVxZFCP9uN27s6cy%2F3GHov0PJPP9v0%2F%2BvXXeG77%2FiZE%2FwD6ufX24%2Fziiiv0vFbL0%2FVH zGF%2Bz8v%2FAG00vG2lf2n0%2FwAkg%2FhjGP8AOa4mHSv89%2F8A9fp6D1zRRXRhZyWCaTsttO1v%2BB%2FW lvBeuYa6%2B911PSLOx5%2FznnP49%2Bnrx1rbs%2Bp%2Bo%2FmKKK%2BaxTb5rvv%2FAO3HvbbCab%2FyEl%2FD%2BdfX 3wT1b%2FiZf9wv1z6%2F5x3%2FAAoormjpneTNaOy29EeVmrf9h5xr%2FwAul%2F6TE6TxVBn3%2FX%2FD8Mc1 wPn%2B36f%2FAF6KK%2FqbLfgl6I%2FljF%2FF%2FwBvP8j%2F2Q%3D%3D"/>
    <br/>I'm a bot! Type <b>do help</b> for help on how to use me.
  ]])
end

---- Events

piepan.On ('connect', Shiba.connected)
piepan.On ('message', Shiba.delegateMessage)
