url        = require "url"
async      = require "async"
uuid       = require "node-uuid"
nano       = require "nano"
Event      = require "../event"
Base       = require "./base"
Profiler   = require "../profiler"
defer      = require "../defer"

class CouchDbEventStore extends Base

  constructor: ({@uri, @logger}) ->
    throw new Error "Missing URI" unless @uri
    throw new Error "Missing logger" unless @logger
    uri = url.parse @uri
    @host     = "#{uri.protocol}//#{uri.host}"
    @database = uri.pathname.replace('/', '')
    @server   = nano @host
    @db       = @server.use @database

  setup: (callback) =>
    async.waterfall [
      (next) =>
        @server.db.destroy @database, (err) =>
          err = null if err? and err.status_code is 404
          next err
      (next) =>
        @server.db.create @database, (err) =>
          next err
      (next) =>
        eventViews =
          language: "coffeescript"
          views:
            byEntity:
              map: "(doc) -> if doc.entityUid? then emit [doc.entityUid, doc.timestamp], doc"
            #byEntityEventCount:
            #  map: "(doc) -> if doc.entityUid? then emit doc.entityUid, 1"
            #  reduce: "_sum"
            byTimestamp:
              map: "(doc) -> if doc.entityUid? then emit doc.timestamp, doc"
        @db.insert eventViews, "_design/events", (err) =>
          next err
    ], (err) =>
      callback err

  createNewUid: (callback) ->
    uid = uuid.v4()
    callback null, uid

  findAllEvents: (callback) ->
    @_find "byTimestamp", {}, callback

  findAllEventsByEntityUid: (entityUid, callback) ->
    @_find "byEntity", { startkey: [entityUid], endkey: [entityUid, {}] }, callback

  saveEvent: (event, callback) =>
    @createNewUid (err, eventUid) =>
      return callback err if err?
      event.uid = eventUid
      payload =
        name: event.name
        entityUid: event.entityUid
        timestamp: event.timestamp
        data: {}
        _attachments: {}

      for key, value of event.data
        if value instanceof Buffer
          encodedValue = value.toString "base64"
          payload["_attachments"][key] =
            content_type: "application/octet-stream"
            data: encodedValue
        else
          payload['data'][key] = value

      @db.insert payload, eventUid, (err, body) ->
        return callback err if err?
        callback null, event

  _find: (view, params, callback) ->
    p = new Profiler "CouchDbEventStore#_find(db request)", @logger
    p.start()
    @db.view "events", view, params, (err, body) =>
      p.end()
      if err?
        callback err
      else if not body.rows?
        callback null, []
      else
        @_instantiateEventsFromRows body.rows, callback

  _instantiateEventsFromRows: (rows, callback) ->
    events = []
    return callback null, events if rows.length is 0

    rowsQueue = async.queue (row, rowCallback) =>
      value        = row.value
      uid          = row.id
      name         = value.name
      entityUid = value.entityUid
      data         = value.data
      timestamp    = value.timestamp

      @_loadAttachmentsFromRow row, (err, attachments) ->
        return rowCallback err if err?
        for attachmentName, attachment of attachments
          data[attachmentName] = attachment
        event = new Event
          name: name
          data: data
          uid: uid
          entityUid: entityUid
          timestamp: timestamp

        events.push event
        defer rowCallback
    , 1

    rowsQueue.drain = ->
      callback null, events

    rowsQueue.push rows

  _loadAttachmentsFromRow: (row, callback) ->
    logger      = @logger
    remaining   = Object.keys(row.value._attachments or {}).length
    attachments = {}
    errors      = []
    if remaining is 0
      return callback null, attachments

    attachmentCallback = (err, attachmentName, body) ->
      if err?
        errors.push err
        logger.error "CouchDbEventStore#_loadAttachmentsFromRow", "Error while loading attachment \"#{attachmentName}\": #{err}"
      else
        attachments[attachmentName] = body

      remaining--
      if remaining is 0
        if errors.length > 0
          callback new Error "An error occured while loading attachments"
        else
          callback null, attachments

    for attachmentName of row.value._attachments
      @db.attachment.get row.id, attachmentName, (err, body) ->
        attachmentCallback err, attachmentName, body


module.exports = CouchDbEventStore
