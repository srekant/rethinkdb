module RethinkDB
  # This module contains the RQL query construction functions.  By far
  # the most common way of gaining access to those functions, however,
  # is to include/extend RethinkDB::Shortcuts to gain access to the
  # shortcut <b>+r+</b>.  That shortcut is used in all the examples
  # below.
  module RQL
    # Construct a javascript expression, which may refer to variables in scope
    # (use <b>+to_s+</b> to get the name of a variable query, or simply splice
    # it in).  Defaults to a javascript expression, but if the optional second
    # argument is <b>+:func+</b>, then you may instead provide the body of a
    # javascript function.  Also has the shorter synonym <b>+js+</b>. If you
    # have a table <b>+table+</b>, the following
    # are equivalent:
    #   table.map{|row| row[:id]}
    #   table.map{|row| r.javascript("#{row}.id")}
    #   table.map{|row| r.js("#{row}.id")}
    #   table.map{r[:id]} #implicit variable
    #   table.map{r.js("this.id")} #implicit variable
    #   table.map{r.js("return this.id;", :func)} #implicit variable
    # As are:
    #   r.let([['a', 1],
    #          ['b', 2]],
    #         r.add(:$a, :$b, 1))
    #   r.let([['a', 1],
    #          ['b', 2]],
    #         r.js('a+b+1'))
    def self.javascript(str, type=:expr);
      if    type == :expr then JSON_Expression.new [:javascript, "return #{str}"]
      elsif type == :func then JSON_Expression.new [:javascript, str]
      else  raise TypeError, 'Type of javascript must be either :expr or :func.'
      end
    end

    # Refer to the database named <b>+db_name+</b>.  Usually used as a
    # stepping stone to a table reference.  For instance, to refer to
    # the table 'tbl' in the database 'db1', either of the following
    # work:
    #   db('db1').table('tbl')
    #   db('db1').tbl
    def self.db(db_name); Database.new db_name; end

    # A shortcut for RQL::expr.  The following are equivalent:
    #   r.expr(5)
    #   r[5]
    def self.[](ind); expr ind; end

    # Convert from a Ruby datatype to an RQL query.  More commonly accessed
    # with its shortcut, <b><tt>[]</tt></b>.  Numbers, strings, booleans,
    # arrays, objects, and nil are all converted to their respective JSON types.
    # Symbols that begin with '$' are converted to variables, and symbols
    # without a '$' are converted to attributes of the implicit variable.  The
    # implicit variable is defined for most operations as the current row.  For
    # example, the following are equivalent:
    #   r.db('').Welcome.filter{|row| row[:id].eq(5)}
    #   r.db('').Welcome.filter{r.expr(:id).eq(5)}
    #   r.db('').Welcome.filter{r[:id].eq(5)}
    # Variables are used in e.g. <b>+let+</b> bindings.  For example:
    #   r.let([['a', 1],
    #          ['b', r[:$a]+1]],
    #         r[:$b]*2).run
    # will return 4.  (This notation will usually result in editors highlighting
    # your variables the same as global ruby variables, which makes them stand
    # out nicely in queries.)
    #
    # <b>Note:</b> this function is idempotent, so the following are equivalent:
    #   r[5]
    #   r[r[5]]
    # <b>Note 2:</b> the implicit variable can be dangerous.  Never pass it to a
    # Ruby function, as it might enter a different scope without your
    # knowledge.  In general, if you're doing something complicated, consider
    # naming your variables.
    def self.expr x
      return x if x.kind_of? RQL_Query
      case x.class().hash
      when Table.hash      then x.to_mrs
      when String.hash     then JSON_Expression.new [:string, x]
      when Fixnum.hash     then JSON_Expression.new [:number, x]
      when Float.hash      then JSON_Expression.new [:number, x]
      when TrueClass.hash  then JSON_Expression.new [:bool, x]
      when FalseClass.hash then JSON_Expression.new [:bool, x]
      when NilClass.hash   then JSON_Expression.new [:json_null]
      when Array.hash      then JSON_Expression.new [:array, *x.map{|y| expr(y)}]
      when Hash.hash       then
        JSON_Expression.new [:object, *x.map{|var,term| [var, expr(term)]}]
      when Symbol.hash     then x.to_s[0]=='$'[0] ? var(x.to_s[1..-1]) : getattr(x)
      else raise TypeError, "RQL.expr can't handle '#{x.class()}'"
      end
    end

    # Explicitly construct an RQL variable from a string.  The following are
    # equivalent:
    #   r[:$varname]
    #   r.var('varname')
    # You want to use the second version if the variable name contains
    # funny characters that aren't easily expressed in a symbol.
    def self.var(varname); Var_Expression.new [:var, varname]; end

    # Provide a literal JSON string that will be parsed by the server.  For
    # example, the following are equivalent:
    #   r.expr([1,2,3])
    #   r.json('[1,2,3]')
    def self.json(str); JSON_Expression.new [:json, str]; end

    # Construct an error.  This is usually used in the branch of an <b>+if+</b>
    # expression.  For example:
    #   r.if(r[1] > 2, false, r.error('unreachable'))
    # will only run the error query if 1 is greater than 2.  If an error query
    # does get run, it will be received as a RuntimeError in Ruby, so be
    # prepared to handle it.
    def self.error(err); JSON_Expression.new [:error, err]; end

    # Test a predicate and execute one of two branches (just like
    # Ruby's <b>+if+</b>).  For example, if we have a table
    # <b>+table+</b>:
    #   table.update{|row| r.if(row[:score] < 10, {:score => 10}, {})}
    # will change every row with score below 10 in <b>+table+</b> to have score 10.
    def self.if(test, t_branch, f_branch)
      tb = S.r(t_branch)
      fb = S.r(f_branch)
      if tb.kind_of? fb.class
        resclass = fb.class
      elsif fb.kind_of? tb.class
        resclass = tb.class
      else
        raise TypeError, "Both branches of IF must be of compatible types."
      end
      resclass.new [:if, S.r(test), S.r(t_branch), S.r(f_branch)]
    end

    # Construct a query that binds some values to variable (as specified by
    # <b>+varbinds+</b>) and then executes <b>+body+</b> with those variables in
    # scope.  For example:
    #   r.let([['a', 2],
    #          ['b', r[:$a]+1]],
    #         r[:$b]*2)
    # will bind <b>+a+</b> to 2, <b>+b+</b> to 3, and then return 6.  (It is
    # thus analagous to <b><tt>let*</tt></b> in the Lisp family of languages.)
    # It may also be used with hashes instead of lists, but in that case you
    # give up some power: in particular, you cannot have variables that depend
    # on previous variables, because the order is not guaranteed.  For example:
    #   r.let({:a => 2, :b => 3}, r[:$b]*2) # legal
    #   r.let({:a => 2, :b => r[:$a]+1}, r[:$b]*2) #legality not guaranteed
    def self.let(varbinds, body);
      varbinds.map! { |pair|
        raise SyntaxError,"Malformed LET expression #{body}" if pair.length != 2
        [pair[0].to_s, expr(pair[1])]}
      res = S.r(body)
      res.class.new [:let, varbinds, res]
    end

    # Negate a boolean.  May also be called as if it were a instance method of
    # JSON_Expression for convenience.  The following are equivalent:
    #   r.not(true)
    #   r[true].not
    def self.not(pred); JSON_Expression.new [:call, [:not], [S.r pred]]; end

    # Get an attribute of the implicit variable (usually done with
    # RQL::expr).  Getting an attribute explicitly is useful if it has an
    # odd name that can't be expressed as a symbol (or a name that starts with a
    # $).  Synonyms are <b>+get+</b> and <b>+attr+</b>.  The following are all
    # equivalent:
    #   r[:id]
    #   r.expr(:id)
    #   r.getattr('id')
    #   r.get('id')
    #   r.attr('id')
    def self.getattr(attrname)
      JSON_Expression.new [:call, [:implicit_getattr, attrname], []]
    end

    # Test whether the implicit variable has a particular attribute.  Synonyms
    # are <b>+has+</b> and <b>+attr?+</b>.  The following are all equivalent:
    #   r.hasattr('name')
    #   r.has('name')
    #   r.attr?('name')
    def self.hasattr(attrname)
      JSON_Expression.new [:call, [:implicit_hasattr, attrname], []]
    end

    # Construct an object that is a subset of the object stored in the implicit
    # variable by extracting certain attributes.  Synonyms are <b>+pick+</b> and
    # <b>+attrs+</b>.  The following are all equivalent:
    #   r[{:id => r[:id], :name => r[:name]}]
    #   r.pickattrs(:id, :name)
    #   r.pick(:id, :name)
    #   r.attrs(:id, :name)
    def self.pickattrs(*attrnames)
      JSON_Expression.new [:call, [:implicit_pickattrs, *attrnames], []]
    end

    # Construct an object that is a subset of the object stored in the
    # implicit variable by removing certain attributes.  The following
    # are equivalent:
    #   r[[{:a => 1, :b => 2}]].map{r.without(:b)}
    #   r[[{:a => 1}]]
    def self.without(*attrnames)
      JSON_Expression.new [:call, [:implicit_without, *attrnames], []]
    end

    # Add two or more numbers together.  May also be called as if it
    # were a instance method of JSON_Expression for convenience, and
    # overloads <b><tt>+</tt></b> if the lefthand side is a query.
    # The following are all equivalent:
    #   r.add(1,2)
    #   r[1].add(2)
    #   (r[1] + 2) # Note that (1 + r[2]) is *incorrect* because Ruby only
    #              # overloads based on the lefthand side.
    # The following is also legal:
    #   r.add(1,2,3)
    # Add may also be used to concatenate arrays.  The following are equivalent:
    #   r[[1,2,3]]
    #   r.add([1, 2], [3])
    def self.add(a, b, *rest)
      JSON_Expression.new [:call, [:add], [S.r(a), S.r(b), *(rest.map{|x| expr x})]];
    end

    # Subtract one number from another.
    # May also be called as if it were a instance method of JSON_Expression for
    # convenience, and overloads <b><tt>-</tt></b> if the lefthand side is a
    # query.  Also has the shorter synonym <b>+sub+</b>. The following are all
    # equivalent:
    #   r.subtract(1,2)
    #   r[1].subtract(2)
    #   r.sub(1,2)
    #   r[1].sub(2)
    #   (r[1] - 2) # Note that (1 - r[2]) is *incorrect* because Ruby only
    #              # overloads based on the lefthand side.
    def self.subtract(a, b); JSON_Expression.new [:call, [:subtract], [S.r(a), S.r(b)]]; end

    # Multiply two numbers together.  May also be called as if it were
    # a instance method of JSON_Expression for convenience, and
    # overloads <b><tt>+</tt></b> if the lefthand side is a query.
    # Also has the shorter synonym <b>+mul+</b>.  The following are
    # all equivalent:
    #   r.multiply(1,2)
    #   r[1].multiply(2)
    #   r.mul(1,2)
    #   r[1].mul(2)
    #   (r[1] * 2) # Note that (1 * r[2]) is *incorrect* because Ruby only
    #              # overloads based on the lefthand side.
    # The following is also legal:
    #   r.multiply(1,2,3)
    def self.multiply(a, b, *rest)
      JSON_Expression.new [:call, [:multiply], [S.r(a), S.r(b), *(rest.map{|x| S.r x})]];
    end

    # Divide one number by another.  May also be called as if it were
    # a instance method of JSON_Expression for convenience, and
    # overloads <b><tt>/</tt></b> if the lefthand side is a query.
    # Also has the shorter synonym <b>+div+</b> and overloads
    # <b>+/+</b> if the lefthand side is a query. The following are
    # all equivalent:
    #   r.divide(1,2)
    #   r[1].divide(2)
    #   r.div(1,2)
    #   r[1].div(2)
    #   (r[1] / 2) # Note that (1 / r[2]) is *incorrect* because Ruby only
    #              # overloads based on the lefthand side.
    def self.divide(a, b); JSON_Expression.new [:call, [:divide], [S.r(a), S.r(b)]]; end

    # Take one number modulo another.  May also be called as if it
    # were a instance method of JSON_Expression for convenience, and
    # overloads <b><tt>%</tt></b> if the lefthand side is a query.
    # Also has the shorter synonym <b>+mod+</b>. The following are all
    # equivalent:
    #   r.modulo(1,2)
    #   r[1].modulo(2)
    #   r.mod(1,2)
    #   r[1].mod(2)
    #   (r[1] % 2) # Note that (1 % r[2]) is *incorrect* because Ruby only
    #              # overloads based on the lefthand side.
    def self.modulo(a, b); JSON_Expression.new [:call, [:modulo], [S.r(a), S.r(b)]]; end

    # Returns true if any of its arguments are true.  Sort of like
    # <b>+or+</b> in ruby, but takes arbitrarily many arguments and is
    # *not* guaranteed to short-circuit.  May also be called as if it
    # were a instance method of JSON_Expression for convenience, and
    # overloads <b><tt>|</tt></b> if the lefthand side is a query.
    # Also has the synonym <b>+or+</b>.  The following are all
    # equivalent:
    #   r[true]
    #   r.any(false, true)
    #   r.or(false, true)
    #   r[false].any(true)
    #   r[false].or(true)
    #   (r[false] | true) # Note that (false | r[true]) is *incorrect* because
    #                     # Ruby only overloads based on the lefthand side
    def self.any(pred, *rest)
      JSON_Expression.new [:call, [:any], [S.r(pred), *(rest.map{|x| S.r x})]];
    end

    # Returns true if all of its arguments are true.  Sort of like
    # <b>+and+</b> in ruby, but takes arbitrarily many arguments and
    # is *not* guaranteed to short-circuit.  May also be called as if
    # it were a instance method of JSON_Expression for convenience,
    # and overloads <b><tt>&</tt></b> if the lefthand side is a query.
    # Also has the synonym <b>+and+</b>.  The following are all
    # equivalent:
    #   r[false]
    #   r.all(false, true)
    #   r.and(false, true)
    #   r[false].all(true)
    #   r[false].and(true)
    #   (r[false] & true) # Note that (false & r[true]) is *incorrect* because
    #                     # Ruby only overloads based on the lefthand side
    def self.all(pred, *rest)
      JSON_Expression.new [:call, [:all], [S.r(pred), *(rest.map{|x| S.r x})]];
    end

    # TODO: make union work for arrays too
    #
    # Take the union of 0 or more sequences <b>+seqs+</b>.  Note that
    # unlike normal set union, duplicate values are preserved.  May
    # also be called as if it were a instance method of Read_Query,
    # for convenience.  For example, if we have a table
    # <b>+table+</b>, the following are equivalent:
    #   r.union(table.map{r[:id]}, table.map{r[:num]})
    #   table.map{r[:id]}.union(table.map{r[:num]})
    def self.union(*seqs)
      #TODO: this looks wrong...
      if seqs.all? {|x| x.kind_of? JSON_Expression}
        resclass = JSON_Expression
      elsif seqs.all? {|x| x.kind_of? Stream_Expression}
        resclass = Stream_Expression
      else
        raise TypeError, "All arguments to UNION must be of the same type."
      end
      resclass.new [:call, [:union], seqs.map{|x| S.r x}];
    end

    # Merge two objects together with a preference for the object on the right.
    # The resulting object has all the attributes in both objects, and if the
    # two objects share an attribute, the value from the object on the right
    # "wins" and is included in the final object.  May also be called as if it
    # were an instance method of JSON_Expression, for convenience.  The following are
    # equivalent:
    #   r[{:a => 10, :b => 2, :c => 30}]
    #   r.mapmerge({:a => 1, :b => 2}, {:a => 10, :c => 30})
    #   r[{:a => 1, :b => 2}].mapmerge({:a => 10, :c => 30})
    def self.mapmerge(obj1, obj2)
      JSON_Expression.new [:call, [:mapmerge], [S.r(obj1), S.r(obj2)]]
    end

    # Check whether two JSON expressions are equal.  May also be called as
    # if it were a member function of JSON_Expression for convenience.  Has the
    # synonym <b>+equals+</b>.  The following are all equivalent:
    #   r[true]
    #   r.eq 1,1
    #   r[1].eq(1)
    #   r.equals 1,1
    #   r[1].equals(1)
    # May also be used with more than two arguments.  The following are
    # equivalent:
    #   r[false]
    #   r.eq(1, 1, 2)
    def self.eq(*args)
      JSON_Expression.new [:call, [:compare, :eq], args.map{|x| S.r x}]
    end

    # Check whether two JSON expressions are *not* equal.  May also be
    # called as if it were a member function of JSON_Expression for convenience.  The
    # following are all equivalent:
    #   r[true]
    #   r.ne 1,2
    #   r[1].ne(2)
    #   r.not r.eq(1,2)
    #   r[1].eq(2).not
    # May also be used with more than two arguments.  The following are
    # equivalent:
    #   r[true]
    #   r.ne(1, 1, 2)
    def self.ne(*args)
      JSON_Expression.new [:call, [:compare, :ne], args.map{|x| S.r x}]
    end

    # Check whether one JSON expression is less than another.  May also be
    # called as if it were a member function of JSON_Expression for convenience.  May
    # also be called as the infix operator <b><tt> < </tt></b> if the lefthand
    # side is a query.  The following are all equivalent:
    #   r[true]
    #   r.lt 1,2
    #   r[1].lt(2)
    #   r[1] < 2
    # Note that the following is illegal, because Ruby only overloads infix
    # operators based on the lefthand side:
    #   1 < r[2]
    # May also be used with more than two arguments.  The following are
    # equivalent:
    #   r[true]
    #   r.lt(1, 2, 3)
    def self.lt(*args)
      JSON_Expression.new [:call, [:compare, :lt], args.map{|x| S.r x}]
    end

    # Check whether one JSON expression is less than or equal to another.
    # May also be called as if it were a member function of JSON_Expression for
    # convenience.  May also be called as the infix operator <b><tt> <= </tt></b>
    # if the lefthand side is a query.  The following are all equivalent:
    #   r[true]
    #   r.le 1,1
    #   r[1].le(1)
    #   r[1] <= 1
    # Note that the following is illegal, because Ruby only overloads infix
    # operators based on the lefthand side:
    #   1 <= r[1]
    # May also be used with more than two arguments.  The following are
    # equivalent:
    #   r[true]
    #   r.le(1, 2, 2)
    def self.le(*args)
      JSON_Expression.new [:call, [:compare, :le], args.map{|x| S.r x}]
    end

    # Check whether one JSON expression is greater than another.
    # May also be called as if it were a member function of JSON_Expression for
    # convenience.  May also be called as the infix operator <b><tt> > </tt></b>
    # if the lefthand side is an RQL query.  The following are all equivalent:
    #   r[true]
    #   r.gt 2,1
    #   r[2].gt(1)
    #   r[2] > 1
    # Note that the following is illegal, because Ruby only overloads infix
    # operators based on the lefthand side:
    #   2 > r[1]
    # May also be used with more than two arguments.  The following are
    # equivalent:
    #   r[true]
    #   r.gt(3, 2, 1)
    def self.gt(*args)
      JSON_Expression.new [:call, [:compare, :gt], args.map{|x| S.r x}]
    end

    # Check whether one JSON expression is greater than or equal to another.
    # May also be called as if it were a member function of JSON_Expression for
    # convenience.  May also be called as the infix operator <b><tt> >= </tt></b>
    # if the lefthand side is a query.  The following are all equivalent:
    #   r[true]
    #   r.ge 1,1
    #   r[1].ge(1)
    #   r[1] >= 1
    # Note that the following is illegal, because Ruby only overloads infix
    # operators based on the lefthand side:
    #   1 >= r[1]
    # May also be used with more than two arguments.  The following are
    # equivalent:
    #   r[true]
    #   r.ge(2, 2, 1)
    def self.ge(*args)
      JSON_Expression.new [:call, [:compare, :ge], args.map{|x| S.r x}]
    end

    # Create a new database with name <b>+db_name+</b>.  Either
    # returns <b>+nil+</b> or raises an error.
    def self.create_db(db_name); Meta_Query.new [:create_db, db_name]; end

    # List all databases.  Either returns an array of strings or raises an error.
    def self.list_dbs(); Meta_Query.new [:list_dbs]; end

    # Drop the database with name <b>+db_name+</b>.  Either returns
    # <b>+nil+</b> or raises an error.
    def self.drop_db(db_name); Meta_Query.new [:drop_db, db_name]; end

    # Dereference aliases (seet utils.rb)
    def self.method_missing(m, *args, &block) # :nodoc:
      (m2 = C.method_aliases[m]) ? self.send(m2, *args, &block) : super(m, *args, &block)
    end
  end
end