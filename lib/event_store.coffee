CouchDbEventStore = require "./event_store/couchdb"
MongoDbEventStore = require "./event_store/mongodb"

module.exports =
  CouchDb: CouchDbEventStore
  MongoDb: MongoDbEventStore
