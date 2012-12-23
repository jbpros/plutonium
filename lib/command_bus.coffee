DomainRepository = require "./domain_repository"

class CommandBus

  constructor: ({@domainRepository, @logger}) ->
    throw new Error "Missing domain repository" unless @domainRepository?
    throw new Error "Missing logger" unless @logger?

    @commandHandlers = {}

  registerCommandHandler: (command, handler) ->
    @commandHandlers[command] = handler

  executeCommand: (commandName, args..., callback) ->
    domainRepository = @domainRepository
    logger           = @logger
    @getHandlerForCommand commandName, (err, commandHandler) ->
      return callback err if err?

      proceed = (callback) ->
        args.push callback
        commandHandler.apply null, args
      # let synchronous stuff happen so that events can be registered to in calling code:
      process.nextTick ->
        domainRepository.transact proceed, (err) ->
          if err?
            logger.warn "CommandBus#executeCommand", "transaction failed (#{err})"
          else
            logger.debug "CommandBus#executeCommand", "transaction succeeded"
      callback null

  getHandlerForCommand: (commandName, callback) ->
    commandHandler = @commandHandlers[commandName]
    if not commandHandler?
      callback new Error "No handler for command \"#{commandName}\" was found"
    else
      callback null, commandHandler

module.exports = CommandBus
