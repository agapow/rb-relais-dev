#! /usr/bin/env ruby
# -*- coding: utf-8 -*-

# Support for ubiquitous development tricks and idioms.
#
# Together, the Ruby standard and third-party libraries present a cacophony of 
# idioms for reading and writing data: methods that accept only IO objects or
# data strings or file paths, IO objects that automatically close or not, IO
# objects that are created explicitly or implicitly ... see the standard CSV
# module for an example of this mess. Relais::Dev::IO unifies these in a
# consistent set of idioms that should be quick to use and easy to remember. In
# summary:
#
# * IO is encapsulated in reader and writer objects. 
# * Readers and Writers are constructed with either open IO objects or
#   filepaths. Filepaths are opened and closed automatically.
# * Data is passed via "read" and "write" methods. For convenience, readers have
#   methods that accept blocks to which they can pass data.
# * IO is explicitly concluded with a `finish` method.
# * For convenience, readers and writers have a `use_with` class method that
#   creates the reading/writing object, passes it to a block for the user to
#   capture/pass the data and closes it up afterwards, effectively wrapping the
#   lifecycle.
# * For similar convenience, "quick" methods are provided which wrap the
#   reader/writer lifecycle, capturing/passing the data in one pass.
# * Reasonable default arguments are provided that be suitable for most cases
#   and so not need to be explicitly specified.
# * Developer should subclass the bases provided to save work and to provide a
#   consistent interface.
#
# @example
#   # simple data reading, path is opened and closed
#   rdr = BaseReader('file/path', {:mode=>'rb'})
#   data = rdr.read()
#   rdr.finish()
#
#   # pass open IO object instead
#   hndl = File.open('file/path', {:mode=>'rb'})
#   rdr = BaseReader(hndl)
#
#   # simpler
#   rdr = BaseReader('file/path')
#   ...
#
#   # even simpler
#   BaseReader::use_with('file/path') { |rdr|
#      # do something with data ...
#   }
#
#   # simplest
#   data = quick_read('file/path')
#
#   # equivalent write calls
#   wrtr = BaseWriter('file/path', {:mode=>'wb'})
#   wrtr.write(data)
#   wrtr.finish()
#
#   # or ...
#   quick_write('file/path', data)

### IMPORTS

require 'ostruct'
require 'logger'
require 'test/unit/assertions'

require 'relais-dev/base/fixedstruct'
require 'relais-dev/errors'



### IMPLEMENTATION

# submodules that we provide

# local code
module Relais
	module Dev
		module Common
			
			RBE = Relais::Dev::Errors
			include Test::Unit::Assertions
			LEVELS = %w(DEBUG INFO WARN ERROR FATAL ANY)
			
			def level_to_str(lvl)
				return LEVELS[lvl] || LEVELS[-1]
			end
			
			# Options and their default values for scripts and functions.
			#
			# Options are traditionally handled within Ruby by juggling and merging
			# hashes. This works fine except for the danger of mispelling silently
			# going unnoticed:
			#
			#   options = {:overwrite_data => true}
			#   ...
			#   options[:overwrite_date] = false
			#   ... 
			#   if options[:overwrite_data]
			#   ...
			#
			# and the slightly awkward lookup required to get and set value. This
			# class solves these problems by implementing options as an OpenStruct
			# that cannot add attributes after construction. Thus options are
			# accessed as simple attributes and attempting to access a mispelt
			# options results in an error. Also, readability is helped by making
			# intent clear in the class name: 
			#
			#   options = Options.new(:overwrite_data => true, :message => "foo") 
			#   ...
			#   options.overwrite_date = false   # error!
			#   ... 
			#   if options.overwrite_data        # easier
			#   ...
			# 
			# Options can be created with the same syntax as OpenStruct:
			#
			#   # pass keyword arguments
			#   my_opt = Options.new(:overwrite_data => true, :message => "foo")
			#   # or a hash if you prefer
			#   my_opt = Options.new({:overwrite_data => true, :message => "foo"})
			#
			# Usage would typically be:
			#
			#   def myfunc (arg1, arg2, opts={})
			#      options = Options.new(
			#        :overwrite_data => true,
			#        :message =>  "foo",
			#      ).update(opts)
			#
			class Options < Relais::Dev::Base::FixedStruct
				# TODO: replace "attribute" and "field" with "instance variable"
			
				def method_missing(mid, *args) # :nodoc:
					# TODO: should call Object.method_missing, bypassing OpenStruct
					raise TypeError, "can't add to #{self.class} once created", caller(1)
				end
			
				# Remove the named attribute from the object.
				#
				def delete_field(name)
					raise TypeError, "can't delete from #{self.class} once created", caller(1)
				end
			
				# Compare this object and +other+ for equality.
				#
				def ==(other)
					# TODO: change to do class comparison and make clearer 
					return false unless(other.kind_of?(OpenStruct))
					return @table == other.table
				end
			
				# Update the fields with the passed values.
				#
				# @param [Hash, #each_pair] hsh A hash of attribute (key) / value
				#   pairs.
				# 
				# Normally this would be used to merge passed option values with a
				# default set. It differs from the Hash method by raising an error
				# if the update refers to an attribute that doesn't exist.
				def update(hsh)
					hsh.each_pair { |k,v|
						# ???: not sure if this is the right Ruby idiom
						instance_variable_set("@"+k.to_s, v)	
					}
					return self
				end
			
			end
			
			
			# Create an options object with these default values.
			#
			# @see {Options}
			#
			# This is a simple bit of semantic sugar
			def default_options(*args)
				return Options.new(*args)
			end
			
			
			
			# Print the passed objects, and complete with a linebreak.
			#
			# @param [] args ant objects that can be printed 
			#
			# This is a simple convenience function, prompted by the irritation of
			# having to add '\n' after every "diagnostic printf" .
			#
			# @example
			#   >>> printn('foo')
			#   'foo'
			#
			def printn(*args)
				print(*args)
				print "\n"
			end
			 
			 
			# Raise an exception unless the passed condition is met
			#
			# @param [Boolean] cond A test that evaulates to a boolean
			# @param [Hash] options An options hash
			# @option options [Exception class] error An exception class, by
			#   default AssertionError
			# @option options [String] error An error message, by default "an
			#   unknown error has occurred" 
			#
			# Assertions are provided within Ruby, but only within the testing
			# frameworks. This method plugs that gap and provides some useful extra
			# functionality, such as specifying error class and message.
			#
			# @example
			#   raise_unless (day_of_month <= 32)
			#   raise_unless (filepath.exists, {:error=>IOError})
			#   raise_unless (denominator != 0, {:msg=>"division by zero!"})
			#
			def raise_unless(cond, opts={})
				# TODO: use globals to set the default err logger and stream
				# TODO: need a better word than 'defaults'
				defaults = {
					:err_class => RBE::AssertionError,
					:msg => "an unknown error has occurred and an exception has been raised",
					:logger => nil,
					:lvl => Logger::ERROR,
					:err_stream => $stderr,
				}.merge(opts)
				unless (cond)
					if defaults[:err_stream]
						print_error(defaults[:msg], 
							{:lvl=>defaults[:lvl], :stream=>defaults[:err_stream]})
					end
					if defaults[:logger]
						log_error(defaults[:msg], defaults[:logger],
							{:lvl=>defaults[:lvl]})	
					end
					raise defaults[:err_class].new(defaults[:msg])
				end
			end
			 
			 
			# Raise an exception unless the passed condition is met
			#
			# @param [Boolean] cond A test that evaulates to a boolean
			# @param [Hash] options An options hash
			# @option options [Exception class] error An exception class, by
			#   default AssertionError
			# @option options [String] error An error message, by default "an
			#   unknown error has occurred" 
			#
			# Assertions are provided within Ruby, but only within the testing
			# frameworks. This method plugs that gap and provides some useful extra
			# functionality, such as specifying error class and message.
			#
			# @example
			#   raise_unless (day_of_month <= 32)
			#   raise_unless (filepath.exists, {:error=>IOError})
			#   raise_unless (denominator != 0, {:msg=>"division by zero!"})
			#
			def die_unless(cond, opts={})
				defaults = {
					:ret_code => -1,
					:msg => "an unknown error has occurred and the program will exit",
					:logger => nil,
					:lvl => Logger::FATAL,
					:err_stream => $stderr,
				}.merge(opts)
				unless (cond)
					if defaults[:err_stream]
						print_error(msg, {:lvl=>lvl, :stream=>stream})
					end
					if defaults[:logger]
						log_error(msg, logger, {:lvl=>lvl})	
					end
					exit(ret_code)	
				end
			end
			 
			 
			# Print an error message to a stream.
			#
			# @private
			#
			# @param [String, #to_s] msg An error message to report
			# @param [Hash] options
			# @option options [IO] stream The stream to send the message to, by
			#   default STDERR.
			# @option options [#to_s] lvl The error level, usually a logging level
			#   but possibly a descriptive string, Logger::ERROR by default.
			#
			# This is just an internal helper function, to send an message to the
			# screen in the events of errors. It is used by assertion-like
			# functions.
			#
			def print_error (msg, opts={})
				## Preconditions & preparation:
				# ???: you can use STDERR or $stderr, unsure which is best
				defaults = {
					:stream => $stderr,
					:lvl => Logger::ERROR,
				}.merge(opts)
				if defaults[:lvl].is_a?(Fixnum)
					defaults[:lvl] = LEVELS[defaults[:lvl]] || LEVELS[-1]
				end
				## Main:
				lvl_str = defaults[:lvl]
				defaults[:stream].write("#{lvl_str.empty?()? '': lvl_str + ': '}#{msg}\n")
			end
			 
			 
			# Print an error message to a logger.
			#
			# @private
			#
			# @param [String, #to_s] msg An error message to report
			# @param [Logger] logger A logger to receieve the error message
			# @param [Hash] options
			# @option options [#to_s] lvl The error level, which should be a
			#   logging level but may be a descriptive string, Logger::ERROR by
			#   default.
			#
			# This is just an internal helper function, to send an message to a
			# logger in the events of errors. It is used by assertion-like
			# functions. Better and more powerful logging functions can be found
			# elsewhere.
			#
			def log_error(msg, logger, opts={})
				## Preconditions & preparation:
				defaults = {
					:lvl => Logger::ERROR,
				}.merge(opts)
				## Main:
				logger.add(defaults[:lvl], msg)
			end

		end
	end
end

