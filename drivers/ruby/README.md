#### The Ruby Client

If you're here to hack on the Ruby client, I apologize in advance.
The code was never the cleanest, and it's been through several messy
overhauls since it was first written.

#### Usage

The easiest way to start playing with the ruby client in this
directory (as opposed to the globally installed one) is to use `irb`
and load the `quickstart.rb` script:

```rb
~/rethinkdb/drivers/ruby $ PORT_OFFSET=0 irb --readline
irb(main):001:0> load 'quickstart.rb'
=> true
irb(main):002:0> r.db_list.run
=> ["test"]
```

#### Hacking

Here's a rough overfiew of the files in `lib`:
* **rethinkdb.rb** -- The file users load.  Include severything else
    and holds a little bit of wrapper convenience code.
* **func.rb** -- The code that implements all the ReQL commands.
* **shim.rb** -- Code for constructing ReQL values, and for converting
    ReQL values to and from JSON.
* **net.rb** -- Code for talking to the RethinkDB server and managing
    connections/cursors.
* **rpp.rb** -- Here be dragons.  Code for pretty-printing ReQL
    values, with or without backtraces.
* **exc.rb** -- The exceptions the driver will throw.

#### Testing

You can find the tests for this and the other two official drivers at
`rethinkdb/test/rql_test/` .
