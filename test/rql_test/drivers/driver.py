from sys import path
import sys
import pdb
import collections
import types
import re
path.insert(0, "../../drivers/python2")

from os import environ
import rethinkdb as r 

JSPORT = int(sys.argv[1])
CPPPORT = int(sys.argv[2])

# -- utilities --

def print_test_failure(test_name, test_src, message):
    print ''
    print "TEST FAILURE: %s" % test_name
    print "TEST BODY: %s" % test_src
    print message
    print ''

class Lst:
    def __init__(self, lst):
        self.lst = lst

    def __eq__(self, other):
        if not hasattr(other, '__iter__'):
            return False

        if len(self.lst) != len(other):
            return False
        
        for i in xrange(len(self.lst)):
            if not (self.lst[i] == other[i]):
                return False

        return True

    def __repr__(self):
        return repr(self.lst)

class Bag(Lst):
    def __init__(self, lst):
        self.lst = sorted(lst)

    def __eq__(self, other):
        if not hasattr(other, '__iter__'):
            return False

        other = sorted(other)

        if len(self.lst) != len(other):
            return False
        
        for i in xrange(len(self.lst)):
            if not (self.lst[i] == other[i]):
                return False

        return True

class Dct:
    def __init__(self, dct):
        self.dct = dct
    
    def __eq__(self, other): 
        if not isinstance(other, types.DictType):
            return False

        for key in self.dct.keys():
            if not key in other.keys():
                return False
            if not (self.dct[key] == other[key]):
                return False
        return True

    def __repr__(self):
        return repr(self.dct)

class Err:
    def __init__(self, err_type=None, err_msg=None, err_frames=None):
        self.etyp = err_type
        self.emsg = err_msg
        self.frames = None #err_frames # Do not test frames for now, not until they're ready for prime time on the C++ server

    def __eq__(self, other):
        if not isinstance(other, Exception):
            return False

        if self.etyp and self.etyp != other.__class__.__name__:
            return False

        # Strip "offending object" from the error message
        other.message = re.sub(":\n.*", ".", other.message, flags=re.M|re.S)

        if self.emsg and self.emsg != other.message:
            return False

        if self.frames and self.frames != other.frames:
            return False

        return True

    def __repr__(self):
        return "%s(\"%s\")" % (self.etyp, repr(self.emsg) or '')

class Arr:
    def __init__(self, length, thing=None):
        self.length = length
        self.thing = thing

    def __eq__(self, other):
        if not isinstance(other, List):
            return False

        if not self.length == len(other):
            return False

        if self.thing is None:
            return True

        return other == thing

    def __repr__(self):
        return "arr(%d, %s)" % (self.length, repr(self.thing))

class Uuid:
    def __eq__(self, thing):
        if not isinstance(thing, types.StringTypes):
            return False
        return re.match("[a-z0-9]{8}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{12}", thing) != None

    def __repr__(self):
        return "uuid()"

# -- Curried output test functions --

def eq(exp):
    if exp == ():
        return lambda x: True

    if isinstance(exp, list):
        exp = Lst(exp)
    elif isinstance(exp, dict):
        exp = Dct(exp)

    def sub(val):
        if not (val == exp):
            return False
        else:
            return True
    return sub

class PyTestDriver:

    # Set up connections to each database server
    def connect(self):
        #print 'Connecting to JS server on port ' + str(JSPORT)
        #self.js_conn = r.connect(host='localhost', port=JSPORT)

        print 'Connecting to CPP server on port ' + str(CPPPORT)
        print ''
        self.cpp_conn = r.connect(host='localhost', port=CPPPORT)
        self.scope = {}

    def define(self, expr):
        exec(expr, globals(), self.scope)

    def run(self, src, expected, name):

        # Try to build the expected result
        if expected:
            exp_val = eval(expected, dict(globals().items() + self.scope.items()))
        else:
            # This test might not have come with an expected result, we'll just ensure it doesn't fail
            #exp_fun = lambda v: True
            exp_val = ()

        # If left off the comparison function is equality by default
        #if not isinstance(exp_fun, types.FunctionType):
        #    exp_fun = eq(exp_fun)

        # Try to build the test
        try:
            query = eval(src, dict(globals().items() + self.scope.items()))
        except Exception as err:
            if not isinstance(exp_val, Err):
                print_test_failure(name, src, "Error eval'ing test src:\n\t%s" % repr(err))
            elif not eq(exp_val)(err):
                print_test_failure(name, src,
                    "Error eval'ing test src not equal to expected err:\n\tERROR: %s\n\tEXPECTED: %s" %
                        (repr(err), repr(exp_val))
                )

            return # Can't continue with this test if there is no test query

        # Try actually running the test
        try:
            cppres = query.run(self.cpp_conn)

            # And comparing the expected result
            if not eq(exp_val)(cppres):
                print_test_failure(name, src,
                    "CPP result is not equal to expected result:\n\tVALUE: %s\n\tEXPECTED: %s" %
                        (repr(cppres), repr(exp_val))
                )

        except Exception as err:
            if not isinstance(exp_val, Err):
                print_test_failure(name, src, "Error running test on CPP server:\n\t%s" % repr(err))
            elif not eq(exp_val)(err):
                print_test_failure(name, src,
                    "Error running test on CPP server not equal to expected err:\n\tERROR: %s\n\tEXPECTED: %s" %
                        (repr(err), repr(exp_val))
                )

        """
        try:
            jsres = query.run(self.js_conn)

            # And comparing the expected result
            if not eq(exp_val)(jsres):
                print_test_failure(name, src,
                    "JS result is not equal to expected result:\n\tVALUE: %s\n\tEXPECTED: %s" %
                        (repr(jsres), repr(exp_val))
                )

        except Exception as err:
            if not isinstance(exp_val, Err):
                print_test_failure(name, src, "Error running test on JS server:\n\t%s" % repr(err))
            elif not eq(exp_val)(err):
                print_test_failure(name, src,
                    "Error running test on JS server not equal to expected err:\n\tERROR: %s\n\tEXPECTED: %s" %
                        (repr(err), repr(exp_val))
                )
        """

driver = PyTestDriver()
driver.connect()

# Emitted test code will consist of calls to this function
def test(query, expected, name):
    if expected == '':
        expected = None
    driver.run(query, expected, name)

# Emitted test code can call this function to define variables
def define(expr):
    driver.define(expr)

# Emitted test code can call this function to set bag equality on a list
def bag(lst):
    return Bag(lst)

# Emitted test code can call this function to indicate expected error output
def err(err_type, err_msg=None, frames=None):
    return Err(err_type, err_msg, frames)

def arr(length, thing=None):
    return Arr(length, thing)

def uuid():
    return Uuid()
