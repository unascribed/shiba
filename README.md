# Shiba

Shiba is a Mumble bot that connects to an SQL server and responds to text commands with audio / text responses. It's slightly tailor-made, but can be set up to suit anyone's needs.

---

## Dependencies

[Lua 5.1.5](http://www.lua.org/) & [LuaSQL](http://keplerproject.github.io/luasql/doc/us/)

[piepan](https://github.com/layeh/piepan/) - has dependencies on [Go](https://golang.org/), [ffmpeg](https://www.ffmpeg.org/), the [OPUS](https://www.opus-codec.org/) audio codec, and others depending on your own OS.


## Usage

Shiba is run by using piepan from the command line. Making a `bash` or `batch` script is advised.

`shiba.sh`
```
./piepan -server="" -password="" -username="" shiba.lua
```
 See the [piepan](https://github.com/layeh/piepan/blob/master/README.md) docs for more help.

### File Structure

Shiba's root directory should look something like this.
```
- | audio/
- | bin/
  - conf.lua
shiba.lua
piepan
```

Audio files should be placed within sub-directories inside the `audio` directory. You may name the `audio` directory whatever you like (See below for config settings).


### Config

`conf.lua` should contain the following variables:

* `AUDIO_DIR` - The name of your `audio` directory.
* `AFK_ID` - The numeric ID of an applicable AFK Mumble channel.
* `ADMIN_NAME` - The username of someone to allow to execute arbitrary SQL queries.

See below for additional database variables.

### Database

Shiba connects to a MySQL server (default, other drivers available) by way of the config file.

`conf.lua` should contain the following database related variables:

* `DB_NAME` - The name of the database to use.
* `DB_USER` - The username for accessing the database.
* `DB_PASS` - The password for accessing the database.
* `TABLE_AUDIO` - The name of the audio table.
* `TABLE_TEXT` - The name of the text table.

#### Tables

Your SQL server should contain two tables that can be named whatever you like (See above for setting the names in the config):

* `audio_table`
  * `id` - PRIMARY KEY, AUTO_INCREMENT
  * `name` - Name associated with the clip.
  * `cmd` - Command used to trigger the audio clip.
  * `dir` - Sub-directory containing the audio file.
  * `filename` - Name of the file without extension.
  * `ext` - File extension.
* `text_table`
  * `id` - PRIMARY KEY, AUTO_INCREMENT
  * `cmd` - Command used to trigger the chat response.
  * `response` - Text blob that is returned.

A couple SQL queries to create these easily:
```sql
CREATE TABLE `text` (`id` INT(11) NOT NULL AUTO_INCREMENT, `cmd` VARCHAR(255) NOT NULL, `response` VARCHAR(255) NOT NULL, PRIMARY KEY (`id`));
CREATE TABLE `audio` (`id` INT NOT NULL AUTO_INCREMENT, `name` VARCHAR(255) NOT NULL, `cmd` VARCHAR(255) NOT NULL, `dir` VARCHAR(255) NOT NULL, `filename` VARCHAR(255) NOT NULL, `ext` VARCHAR(45) NOT NULL, PRIMARY KEY (`id`);
```

### Commands
Shiba has three main commands: **do**, **say**, and **play**. Multiple commands can be sent in a single message by use of a semi-colon ( **;** ) separator. e.g., `do this; say that; play the other`

#### do
`do` is used for issuing literal commands. Some literal commands take optional parameters that can be passed by using a leading plus sign ( **+** ). e.g., `do volume +0.5`.

##### Chat
* `echo +[TEXT]` - The echo command causes Shiba to say the text string. This command can accept multiple text parameters. e,g. `do echo +this +and +that`
* `help` - The help command prints out information about how to use Shiba.
* `show` - The show command simply lists all literal commands Shiba possesses.

##### Audio
* `stop` - This command stops the _current_ audio clip. It does not empty the queue, see below.
* `find +[QUERY]`  - The find command will return a list of audio commands with names (not commands) containing the query string. Without a query string Shiba will return _all_ entries.
*  `volume +[LEVEL]` - This command sets the volume to a given level between 0 and 1. Without a level parameter the command will simply return the current volume.

##### Queue
* `list queue` - Responds with the number of entries in the queue, and their associated commands in order.
* `shut up` - Removes all entries from the queue, and stops playing sound if anything is playing.

##### Movement
* `move here` - Sent in a private message from another channel will cause Shiba to join the sender's channel.
* `get id` - This will respond to the sender with channel ID of the sender's current channel. Can be sent via private message for debugging purposes. Useful for finding the ID of the server's AFK channel.

##### Database
* `reconnect` - The reconnect command will attempt to refresh Shiba's connection to the SQL server. If you find Shiba unresponsive to `say` / `play` commands, or database related `do` commands, try this first. Notifies the sender if successful.
* `query` - Executes an arbitrary query against the database. Requires the sender to be the one defined in the config as ADMIN_NAME.


#### say
The `say` command tries  to match everything that follows it against entries in the database's `text_table`. If the string matches a `cmd` column Shiba will say the associated `response` to the channel Shiba is currently in.

#### play
The `play` command tries to match everything that follows it against entries in the database's `audio_table`. If the string matches a `cmd` column Shiba will attempt to play the associated audio file from disk.

If audio is already playing the audio clip will be added to the end the of queue. After an audio clip is finished playing Shiba will immediately play the next clip in the queue, if one exists.

#### grep
The `grep` command will return all messages in the last 50 that were sent by the given user. This is useful for filtering out noise when someone goes on a stream-of-conciousness rant about something, while others are discussing something.

#### recall (if running archiver.js)
The `recall` command will send an image that has been archived by archiver.js. The first argument is the filename.

## Issues

Shiba commands cannot be passed the following characters as part of their arguments / parameters:

* semi-colon ( **;** )
* plus sign ( **+** )

These are special characters used to break commands into parts, and are currently not able to be escaped. To avoid bad query strings they should not be used as part of searchable database names and commands.

---

Colin 'Oka' Hall-Coates  
[Oka.io](http://oka.io/)
