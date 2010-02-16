#!/usr/bin/ruby
#
# Copyright (c) 2006-2009 National ICT Australia (NICTA), Australia
#
# Copyright (c) 2004-2009 WINLAB, Rutgers University, USA
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
#
# = resourceManager.rb
#
# == Description
#
# This class defines the OMF Resource Manager (RM) entity, which is a daemon
# running on the host (i.e. dom0) of an experimental resource.
# The RM listens for commands from the Users/Slice Manager/Aggregate Managers,
# and executes them on the resource. Typically these commands will request
# the RM to start/stop a virtual machine, and/or start/stop an instance
# of a Resource Controller (RC) within that virtual machine.
# The module ManagerCommands contains the list of commands that the RM 
# understands.
#

require 'omf-common/omfVersion'
require "omf-common/omfCommandObject"
require 'omf-resmgr/xmppCommunicator'
require 'omf-resmgr/managerCommands'

#
# This class defines the Node Agent (NA) entity, which is a daemon
# running on an experimental node.The NA listens for commands
# from the Node Handler, and executes them on the node.
# The module AgentCommands contains the list of commands that the NA 
# understands.
#
class ResourceManager < MObject

  #
  # Our Version Number
  #
  VERSION = OMF::Common::VERSION(__FILE__)
  OMF_MM_VERSION = OMF::Common::MM_VERSION()
  VERSION_STRING = "OMF Resource Manager #{VERSION}"
  
  # File containing image name
  IMAGE_NAME_FILE = '/.omf_imageid'

  include Singleton
  @@instantiated = false

  attr_reader :managerName, :config 
    
  #
  # Return the Instantiation state for this Singleton
  #
  # [Return] true/false
  #
  def ResourceManager.instantiated?
    return @@instantiated
  end   
      
  #
  # Run the main execution loop of the Resource Manager.
  # After starting the RM, this method will loop indefinitely
  #
  def run
    if (! @running.nil?)
      raise "Already running"
    end
    info(VERSION_STRING)
    resetState
    communicator.reset

    @running = ConditionVariable.new
    if @interactive
      require 'irb'
      ARGV.clear
      ARGV << "--simple-prompt"
      ARGV << "--noinspect"
      IRB.start()
    else
      @mutex = Mutex.new
      @mutex.synchronize {
        @running.wait(@mutex)
      }
    end
  end

  #
  # Send an OK reply to the Node Handler (EC). When a command has been 
  # successfully completed, the NA sends an 'HeartBeat' OK message
  # to the EC
  #
  # - cmd = a String with the command that completed successfully
  # - id = the ID of this NA (default = nil)
  # - msgArray = an array with the full received command (name, parameters,...)
  #
  def old_okReply(cmd, id = nil, *msgArray)
    if @allowDisconnection 
      communicator.sendRelaxedHeartbeat()
    else
      communicator.sendHeartbeat()
    end
  end

  def okReply(message, cmdObj)
    ok_reply = communicator.getCmdObject(:OK)
    ok_reply.target = @managerName
    ok_reply.message = message
    ok_reply.cmd = cmdObj.cmdType.to_s
    ok_reply.path = cmdObj.path if cmdObj.path != nil
    ok_reply.value = cmdObj.value if cmdObj.value != nil
    send(ok_reply)
  end


  #
  # Send an ENROLL reply to the Node Handler (EC). When a YOUARE or ALIAS 
  # command has been successfully completed, the NA sends this message
  # to the EC
  #
  # - aliasArray = an array with the names of all the groups within the 
  #              original YOAURE/ALIAS message with which this NA has enrolled
  #
  def enrollReply(aliases = nil)
    enroll_reply = communicator.getCmdObject(:ENROLLED)
    enroll_reply.target = @managerName
    enroll_reply.name = aliases if aliases != nil
    send(enroll_reply)
  end

  def wrongImageReply()
    image_reply = communicator.getCmdObject(:WRONG_IMAGE)
    image_reply.target = @managerName
    image_reply.image = imageName()
    # 'WRONG_IMAGE' message goes even though the node is not enrolled!
    # Thus we make a direct call to the communicator here.
    communicator.sendCmdObject(image_reply)
  end

  #
  # Send an ERROR reply to the Node Handler (EC). When an error occured
  # while executing a command, the NA sends an 'ERROR' message
  # to the EC
  #
  # - cmd = a String with the command that produced the error
  # - id = the ID of this NA (default = nil)
  # - msgArray = an array with the full received command (name, parameters,...)
  #
  def errorReply(message, cmdObj)
    error_reply = communicator.getCmdObject(:ERROR)
    error_reply.target = @managerName
    error_reply.message = message
    error_reply.cmd = cmdObj.cmdType.to_s
    error_reply.path = cmdObj.path if cmdObj.path != nil
    error_reply.appID = cmdObj.appID if cmdObj.appID != nil
    error_reply.value = cmdObj.value if cmdObj.value != nil
    # 'ERROR' message goes even though the node is not enrolled!
    # Thus we make a direct call to the communicator here.
    communicator.sendCmdObject(error_reply)
    #send(:ERROR, cmd, id, *msgArray)
  end

  #
  # Send a text message to the Node Handler (EC). 
  #
  # - msgArray = an array with the full text message to send 
  #
  def send(cmdObj)
    if @enrolled
      communicator.sendCmdObject(cmdObj)
    else
      warn("Not enrolled! Not sending message: '#{cmdObj.to_xml_to.s}'")
    end
  end

  #
  # Set the name of the disk image found when starting up
  #
  # [Return] a String with the disk image's name
  #
  def imageName()
    if (@imageName.nil?)
      if (File.exists?(IMAGE_NAME_FILE))
        File.open(IMAGE_NAME_FILE) { |f|
          @imageName = f.read.chomp
        }
      else
        @imageName = 'unknown'
        MObject.warn("Can't find '#{IMAGE_NAME_FILE}'")
      end
    end
    @imageName
  end

  #
  # Send a message to the Node Handler (EC) when an event related
  # to a particular application has happened. This method is
  # usually called by ExecApp which monitors the application 
  # identified by 'id'.
  #
  # - eventName = a String with the name of event that occured
  # - appID = a String with the ID of the application raising the event 
  # - msg = a String with optional message from the application 
  #
  def onAppEvent(eventName, appId, *msg)
    debug("onAppEvent(event: #{eventName} - app: #{appId}) - '#{msg}'")
    
    # If this NA allows disconnection, then check if the event is the Done message from 
    # the slave Experiment Controller
    if ( @allowDisconnection && (appId == AgentCommands.slaveExpCtlID) )
       if ( eventName.split(".")[0] == "DONE" )
         @expirementDone = true
         debug("#{appId} - DONE - EXPERIMENT DONE with status: #{eventName.split(".")[1]}")
       end
    end
    app_event = communicator.getCmdObject(:APP_EVENT)
    app_event.target = @managerName
    app_event.value = eventName.to_s.upcase
    app_event.appID = appId
    app_event.message = "#{msg}"
    send(app_event)
    #send(:APP_EVENT, eventName.to_s.upcase, appId, *msg)
  end

  #
  # Send a message to the Node Handler (EC) when an event related
  # to a particular device has happened. This method is
  # usually called by a Device instance reporting its state change
  #
  # - eventName = a String with the name of event that occured
  # - deviceName = a String with the name of the device raising the event 
  # - msg = a String with optional message from the device 
  #
  def onDevEvent(eventName, deviceName, *msg)
    debug("onDevEvent(#{eventName}:#{deviceName}): '#{msg}'")
    dev_event = communicator.getCmdObject(:DEV_EVENT)
    dev_event.target = @managerName
    dev_event.value = eventName.to_s.upcase
    dev_event.appID = deviceName
    dev_event.message = "#{msg}"
    send(dev_event)
    #send(:DEV_EVENT, eventName.to_s.upcase, deviceName, *msg)
  end

  #
  # Reset all the internal states of this NA, stop all applications
  # started so far, and remove all loaded network modules
  #
  def reset
    info "\n\n------------ RESET ------------\n"
    # ExecApp.killAll ## NOTE: do we want to kill of the started RC on reset ???
    resetState
    communicator.reset
  end

  # 
  # Reset all the internat states of this RM
  #
  def resetState
    info "Agent: '#{@managerName}'"
  end

  # 
  # Make sure that we cleaning up before exiting...
  #
  def cleanUp
    if @running != nil
      info("Cleaning: Disconnect from the PubSub server")
      communicator.quit
      # info("Cleaning: Kill all previously started Applications")
      # ExecApp.killAll ## NOTE: do we want to kill of the started RC on reset ???
      info("Cleaning: Exit")
      info("\n\n------------ EXIT ------------\n")
    end
  end

  #
  # Parse the command line arguments which were used when starting this RM
  #
  # - args = the command line arguments
  #
  def parseOptions(args)
    require 'optparse'

    cfgFile = nil
    @interactive = false
    @logConfigFile = ENV['RES_MGR_LOG'] || "/etc/omf-resmgr-#{OMF_MM_VERSION}/omf-resmgr_log.xml"

    opts = OptionParser.new
    opts.banner = "Usage: omf-resmgr [options]"
    @config = {:comm => {}, :manager => {}}

    # Communication Options 
    opts.on("--control-if IF",
      "Name of interface attached to the control and management network [#{@localIF}]") {|name|
      @config[:comm][:control_if] = name
    }
    opts.on("--xmpp-server HOST",
      "Hostname or IP address of the XMPP server to connect to") {|name|
      @config[:comm][:xmpp_server] = name
    }
    
    # Instance Options
    opts.on('--name NAME',
      "Checkin name of the manager (unique HRN for this resource)") {|name|
      @config[:manager][:name] = name
    }

    # General Options
    opts.on("-i", "--interactive",
      "Run the manager in interactive mode") {
      @interactive = true
    }
    opts.on("--log FILE",
      "File containing logging configuration information") {|file|
      @logConfigFile = file
    }
    opts.on("-n", "--just-print",
      "Print the commands that would be executed, but do not execute them") {
      NodeAgent.JUST_PRINT = true
    }
    opts.on_tail("-h", "--help", "Show this message") { puts opts; exit }
    opts.on_tail("-v", "--version", "Show the version") {
      puts VERSION_STRING
      exit
    }

    rest = opts.parse(args)

    # Make sure log exists ...
    @logConfigFile = File.exists?(@logConfigFile) ? @logConfigFile : nil
    MObject.initLog('ResManager', nil, {:configFile => @logConfigFile})

    # Read config file
    if cfgFile.nil?
      name = "omf-resmgr.yaml"
      path = ["../etc/omf-resmgr/#{name}", "/etc/omf-resmgr-#{OMF_MM_VERSION}/#{name}"]
      cfgFile = path.detect {|f|
        File.readable?(f)
      }
    else
      if (!File.readable?(cfgFile))
        raise "Can't find configuration file '#{cfgFile}'"
      end
    end
    if (cfgFile.nil?)
      raise "Can't find a configuration file"
    else
      require 'yaml'
      h = YAML::load_file(cfgFile)
      if ((p = h[:rmanager]) == nil)
        raise "Missing ':rmanager' root in '#{cfgFile}'"
      end
      @config = p.merge_deep!(@config)
    end

    # At this point, we should now have a name 
    if @config[:manager][:name] == nil 
      raise "Manager's Name is not defined in config file or as arguments!"
    else
      if @config[:manager][:name] == 'default' 
        warn "Using Hostname as the default name for this manager"
        @config[:manager][:name] = `/bin/hostname`.chomp
      end
      @managerName = @config[:manager][:name] 
    end	    
    
  end

  #
  # Return the instance of the Communicator module associated to this NA
  #
  # [Return] a Communicator object 
  #
  def communicator()
    XMPPCommunicator.instance
  end

  #
  # Execute a command received from the Eexperiment Controller
  #
  # - cmdObj = an Object holding all the information to execute a 
  #            given command (name, parameters,...)
  #
  # TODO: for the moment this is only used when an XML EXECUTE command is 
  # received, because we need to get the OML configuration (in XML). In the
  # future, all comms between EC and RC should use this scheme, and this should
  # be more clean.
  #
  def execCommand(cmdObj)
  
    debug "Processing '#{cmdObj.cmdType}' - '#{cmdObj.target}'"
    method = nil
    begin
      method = AgentCommands.method(cmdObj.cmdType.to_s)
    rescue Exception
      error "Unknown method for command '#{cmdObj.cmdType}'"
      errorReply("Unknown command", cmdObj) 
      return
    end
    begin
      reply = method.call(self, cmdObj)
    rescue Exception => err
      error "While executing #{cmdObj.cmdType}: #{err}"
      errorReply("Execution Error (#{err})", cmdObj) 
      return
    end
  end


  ################################################
  private

  #
  # Start this Resource Manager
  #
  def initialize
    @managerName = nil
    @imageName = nil
    @running = nil
    @@instantiated = true
  end

end
