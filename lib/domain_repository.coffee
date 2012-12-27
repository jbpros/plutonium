async = require "async"

COUCHDB_STORE = "couchdb"
REDIS_STORE   = "redis"

class DomainRepository

  constructor: ({@store, @emitter, @logger}) ->
    throw new Error "Missing store" unless @store?
    throw new Error "Missing event bus emitter" unless @emitter?
    throw new Error "Missing logger" unless @logger?
    @aggregates = []
    @directListeners = {}
    @nextDirectListenerKey = 0
    @transactionQueue = async.queue (transaction, done) =>
      @logger.log "transaction", "starting"
      transaction (err) =>
        if err?
          @logger.alert "transaction", "failed, rolling back (#{err})"
          @rollback =>
            @logger.log "transaction", "rolled back (#{@transactionQueue.length()} more transaction(s) in queue)"
            done()
        else
          @logger.log "transaction", "succeeded, comitting"
          @commit =>
            @logger.log "transaction", "committed (#{@transactionQueue.length()} more transaction(s) in queue)"
            done()
    , 1

  transact: (transaction) ->
    @transactionQueue.push transaction
    @logger.log "transaction", "queued (queue size: #{@transactionQueue.length()})"

  createNewUid: (callback) ->
    @store.createNewUid callback

  findAggregateByUid: (Entity, uid, options, callback) ->
    [options, callback] = [{}, options] unless callback?
    callback new Error "Missing entity constructor" unless Entity?
    callback new Error "Missing UID" unless uid?

    @store.findAllByAggregateUid uid, (err, events) ->
      if err?
        callback err
      else
        Entity.buildFromEvents events, callback

  replayAllEvents: (callback) ->
    @store.findAll loadBlobs: true, (err, events) =>
      if events.length > 0
        eventQueue = async.queue (event, eventTaskCallback) =>
          @publishEvent event, eventTaskCallback
        , 1
        eventQueue.drain = callback
        eventQueue.push events
      else
        callback()

  add: (aggregate) ->
    @aggregates.push aggregate

  commit: (callback) ->
    return callback null if @aggregates.length is 0

    committedEvents = []

    aggregateQueue = async.queue (aggregate, aggregateTaskCallback) =>
      firstEvent = aggregate.appliedEvents.shift()

      if firstEvent?
        queue = async.queue (event, eventTaskCallback) =>
          nextEvent = aggregate.appliedEvents.shift()
          queue.push nextEvent if nextEvent?

          @logger.log "commit", "saving event \"#{event.name}\" for aggregate #{event.aggregateUid}"
          @store.saveEvent event, (err, event) =>
            if err?
              eventTaskCallback err
            else
              committedEvents.push event
              eventTaskCallback null
        , 1

        queue.drain = aggregateTaskCallback
        queue.push [firstEvent]
      else
        aggregateTaskCallback null

    , Infinity # TODO determine if it is safe to treat all aggregates in parallel?

    aggregateQueue.drain = (err) =>
      return callback err if err?
      return callback null unless committedEvents.length > 0
      publicationQueue = async.queue (event, publicationCallback) =>
        @publishEvent event, publicationCallback
      , Infinity
      publicationQueue.drain = callback
      publicationQueue.push committedEvents

    aggregateQueue.push @aggregates
    @aggregates = []

  rollback: (callback) ->
    @aggregates.forEach (aggregate) =>
      aggregate.appliedEvents = []
    callback()

  publishEvent: (event, callback) ->
    process.nextTick =>
      @logger.log "publishEvent", "publishing \"#{event.name}\" from aggregate #{event.aggregateUid} to direct listeners"
      @_publishEventToDirectListeners event, (err) =>
        @logger.warn "publishEvent", "a direct listener failed: #{err}" if err?
        @logger.log "publishEvent", "publishing \"#{event.name}\" from aggregate #{event.aggregateUid} to event bus"
        @emitter.emit event, (err) =>
          @logger.log "publishEvent", "event publication failed: #{err}" if err?
          callback err

  # Listen for events before they are published to the event bus
  # Don't use this in reporters/reports! This is reserved for domain routines
  #
  # Options:
  # * synchronous: Boolean - the event listener is considered synchronous, it will not receive any callbacks
  # * once: Boolean - automatically unregisters the listener after one execution
  # * forAggregateUid: String - the listener is executed only if the aggregate UID matches the given string
  onEvent: (eventName, options, listener) ->
    [eventName, options, listener] = [eventName, {}, options] if not listener?
    @directListeners[eventName] ?= {}
    directListeners = @directListeners[eventName]
    directListenerKey = @nextDirectListenerKey++

    if options.synchronous
      syncListener = listener
      listener = (event, callback) ->
        syncListener event
        callback()

    if options.once
      oneTimerListener = listener
      listener = (event, callback) ->
        delete directListeners[directListenerKey]
        oneTimerListener event, callback

    if options.forAggregateUid?
      scopedListener = listener
      listener = (event, callback) ->
        if event.aggregateUid is options.forAggregateUid
          scopedListener event, callback
        else
          callback null

    directListeners[directListenerKey] = listener

  _publishEventToDirectListeners: (event, callback) ->
    directListeners = @directListeners[event.name]

    queue = async.queue (directListener, callback) ->
      directListener event, callback
    , Infinity

    queue.drain = callback
    queuedListeners = false
    for _, directListener of directListeners
      queuedListeners = true unless queuedListeners
      queue.push directListener

    callback null unless queuedListeners

module.exports = DomainRepository
