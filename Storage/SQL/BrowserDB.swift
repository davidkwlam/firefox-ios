/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import XCGLogger
import Shared

private let log = XCGLogger.defaultInstance()

public enum QuerySort {
    case None, LastVisit, Frecency
}

public enum FilterType {
    case ExactUrl
    case Url
    case Guid
    case Id
    case None
}

public class QueryOptions {
    // A filter string to apploy to the query
    public var filter: AnyObject? = nil

    // Allows for customizing how the filter is applied (i.e. only urls or urls and titles?)
    public var filterType: FilterType = .None

    // The way to sort the query
    public var sort: QuerySort = .None

    public init(filter: AnyObject? = nil, filterType: FilterType = .None, sort: QuerySort = .None) {
        self.filter = filter
        self.filterType = filterType
        self.sort = sort
    }
}

let DBCouldNotOpenErrorCode = 200

enum TableResult {
    case Exists
    case Created
    case Updated
    case Failed
}

/* This is a base interface into our browser db. It holds arrays of tables and handles basic creation/updating of them. */
// Version 1 - Basic history table.
// Version 2 - Added a visits table, refactored the history table to be a GenericTable.
// Version 3 - Added a favicons table.
// Version 4 - Added a readinglist table.
// Version 5 - Added the clients and the tabs tables.
// Version 6 - Visit timestamps are now microseconds.
// Version 7 - Eliminate most tables.
public class BrowserDB {
    private var db: SwiftData
    // XXX: Increasing this should blow away old history, since we currently don't support any upgrades.
    private let Version: Int = 7
    private let files: FileAccessor
    private let filename: String
    private let secretKey: String?
    private let schemaTable: SchemaTable<TableInfo>

    private var initialized = [String]()

    // SQLITE_MAX_VARIABLE_NUMBER = 999 by default. This controls how many ?s can
    // appear in a query string.
    static let MaxVariableNumber = 999

    public init(filename: String, secretKey: String? = nil, files: FileAccessor) {
        log.debug("Initializing BrowserDB.")
        self.files = files
        self.filename = filename
        self.schemaTable = SchemaTable()
        self.secretKey = secretKey

        let file = files.getAndEnsureDirectory()!.stringByAppendingPathComponent(filename)
        db = SwiftData(filename: file, key: secretKey, prevKey: nil)

        if AppConstants.BuildChannel == .Developer && secretKey != nil {
            log.debug("Creating db: \(file) with secret = \(secretKey)")
        }

        // Create or update will also delete and create the database if our key was incorrect.
        self.createOrUpdate(self.schemaTable)
    }

    // Creates a table and writes its table info into the table-table database.
    private func createTable<T: Table>(db: SQLiteDBConnection, table: T) -> TableResult {
        log.debug("Try create \(table.name) version \(table.version)")
        if !table.create(db, version: table.version) {
            // If creating failed, we'll bail without storing the table info
            log.debug("Creation failed.")
            return .Failed
        }

        var err: NSError? = nil
        return schemaTable.insert(db, item: table, err: &err) > -1 ? .Created : .Failed
    }

    // Updates a table and writes its table into the table-table database.
    private func updateTable<T: Table>(db: SQLiteDBConnection, table: T) -> TableResult {
        log.debug("Trying update \(table.name) version \(table.version)")
        var from = 0
        // Try to find the stored version of the table
        let cursor = schemaTable.query(db, options: QueryOptions(filter: table.name))
        if cursor.count > 0 {
            if let info = cursor[0] as? TableInfoWrapper {
                from = info.version
            }
        }

        // If the versions match, no need to update
        if from == table.version {
            return .Exists
        }

        if !table.updateTable(db, from: from, to: table.version) {
            // If the update failed, we'll bail without writing the change to the table-table.
            log.debug("Updating failed.")
            return .Failed
        }

        var err: NSError? = nil

        // Yes, we UPDATE OR INSERT… because we might be transferring ownership of a database table
        // to a different Table. It'll trigger exists, and thus take the update path, but we won't
        // necessarily have an existing schema entry -- i.e., we'll be updating from 0.
        if schemaTable.update(db, item: table, err: &err) > 0 ||
           schemaTable.insert(db, item: table, err: &err) > 0 {
            return .Updated
        }
        return .Failed
    }

    // Utility for table classes. They should call this when they're initialized to force
    // creation of the table in the database.
    func createOrUpdate<T: Table>(table: T) -> Bool {
        log.debug("Create or update \(table.name) version \(table.version).")
        var success = true
        db = SwiftData(filename: files.getAndEnsureDirectory()!.stringByAppendingPathComponent(self.filename), key: secretKey)
        let doCreate = { (connection: SQLiteDBConnection) -> () in
            switch self.createTable(connection, table: table) {
            case .Created:
                success = true
                connection.checkpoint()
                return
            case .Exists:
                log.debug("Table already exists.")
                success = true
                return
            default:
                success = false
            }
        }

        if let err = db.transaction({ connection -> Bool in
            // If the table doesn't exist, we'll create it
            if !table.exists(connection) {
                doCreate(connection)
            } else {
                // Otherwise, we'll update it
                switch self.updateTable(connection, table: table) {
                case .Updated:
                    success = true
                    connection.checkpoint()
                    break
                case .Exists:
                    log.debug("Table already exists.")
                    success = true
                    break
                default:
                    log.error("Update failed for \(table.name). Dropping and recreating.")

                    table.drop(connection)
                    var err: NSError? = nil
                    self.schemaTable.delete(connection, item: table, err: &err)

                    doCreate(connection)
                }
            }

            return success
        }) {
            // Err getting a transaction
            success = false
        }

        // If we failed, move the file and try again. This will probably break things that are already
        // attached and expecting a working DB, but at least we should be able to restart.
        if !success {
            log.debug("Couldn't create or update \(table.name).")
            log.debug("Attempting to move \(self.filename) to another location.")

            // Note that a backup file might already exist! We append a counter to avoid this.
            var bakCounter = 0
            var bak: String
            do {
                bak = "\(self.filename).bak.\(++bakCounter)"
            } while self.files.exists(bak)

            success = self.files.move(self.filename, toRelativePath: bak)
            assert(success)

            if let err = db.transaction({ connection -> Bool in
                doCreate(connection)
                return success
            }) {
                success = false;
            }
        }

        return success
    }

    typealias IntCallback = (connection: SQLiteDBConnection, inout err: NSError?) -> Int

    func withConnection<T>(#flags: SwiftData.Flags, inout err: NSError?, callback: (connection: SQLiteDBConnection, inout err: NSError?) -> T) -> T {
        var res: T!
        err = db.withConnection(flags) { connection in
            var err: NSError? = nil
            res = callback(connection: connection, err: &err)
            return err
        }
        return res
    }

    func withWritableConnection<T>(inout err: NSError?, callback: (connection: SQLiteDBConnection, inout err: NSError?) -> T) -> T {
        return withConnection(flags: SwiftData.Flags.ReadWrite, err: &err, callback: callback)
    }

    func withReadableConnection<T>(inout err: NSError?, callback: (connection: SQLiteDBConnection, inout err: NSError?) -> Cursor<T>) -> Cursor<T> {
        return withConnection(flags: SwiftData.Flags.ReadOnly, err: &err, callback: callback)
    }

    func transaction(inout err: NSError?, callback: (connection: SQLiteDBConnection, inout err: NSError?) -> Bool) {
        db.transaction { connection in
            var err: NSError? = nil
            return callback(connection: connection, err: &err)
        }
    }
}

extension BrowserDB {
    public class func varlist(count: Int) -> String {
        return "(" + ", ".join(Array(count: count, repeatedValue: "?")) + ")"
    }

    enum InsertOperation: String {
        case Insert = "INSERT"
        case Replace = "REPLACE"
        case InsertOrIgnore = "INSERT OR IGNORE"
        case InsertOrReplace = "INSERT OR REPLACE"
        case InsertOrRollback = "INSERT OR ROLLBACK"
        case InsertOrAbort = "INSERT OR ABORT"
        case InsertOrFail = "INSERT OR FAIL"
    }

    /**
     * Insert multiple sets of values into the given table.
     *
     * Assumptions:
     * 1. The table exists and contains the provided columns.
     * 2. Every item in `values` is the same length.
     * 3. That length is the same as the length of `columns`.
     * 4. Every value in each element of `values` is non-nil.
     *
     * If there are too many items to insert, multiple individual queries will run
     * in sequence.
     *
     * A failure anywhere in the sequence will cause immediate return of failure, but
     * will not roll back — use a transaction if you need one.
     */
    func bulkInsert(table: String, op: InsertOperation, columns: [String], values: [Args]) -> Success {
        // Note that there's a limit to how many ?s can be in a single query!
        // So here we execute 999 / (columns * rows) insertions per query.
        // Note that we can't use variables for the column names, so those don't affect the count.
        if values.isEmpty {
            log.debug("No values to insert.")
            return succeed()
        }

        let variablesPerRow = columns.count

        // Sanity check.
        assert(values[0].count == variablesPerRow)

        let cols = ", ".join(columns)
        let queryStart = "\(op.rawValue) INTO \(table) (\(cols)) VALUES "

        let varString = BrowserDB.varlist(variablesPerRow)

        let insertChunk: [Args] -> Success = { vals -> Success in
            let valuesString = ", ".join(Array(count: vals.count, repeatedValue: varString))
            let args: Args = vals.flatMap { $0 }
            return self.run(queryStart + valuesString, withArgs: args)
        }

        let rowCount = values.count
        if (variablesPerRow * rowCount) < BrowserDB.MaxVariableNumber {
            return insertChunk(values)
        }

        log.debug("Splitting bulk insert across multiple runs. I hope you started a transaction!")
        let rowsPerInsert = (999 / variablesPerRow)
        let chunks = chunk(values, by: rowsPerInsert)
        log.debug("Inserting in \(chunks.count) chunks.")

        // There's no real reason why we can't pass the ArraySlice here, except that I don't
        // want to keep fighting Swift.
        return walk(chunks, { insertChunk(Array($0)) })
    }

    func runWithConnection<T>(block: (connection: SQLiteDBConnection, inout err: NSError?) -> T) -> Deferred<Result<T>> {
        return DeferredDBOperation(db: db, block: block).start()
    }

    func write(sql: String, withArgs args: Args? = nil) -> Deferred<Result<Int>> {
        return self.runWithConnection() { (connection, err) -> Int in
            err = connection.executeChange(sql, withArgs: args)
            if err == nil {
                let modified = connection.numberOfRowsModified
                log.debug("Modified rows: \(modified).")
                return modified
            }
            return 0
        }
    }

    public func close() {
        db.close()
    }

    func run(sql: String, withArgs args: Args? = nil) -> Success {
        return run([(sql, args)])
    }

    /**
     * Runs an array of sql commands. Note: These will all run in order in a transaction and will block
     * the callers thread until they've finished. If any of them fail the operation will abort (no more
     * commands will be run) and the transaction will rollback, returning a DatabaseError.
     */
    func run(sql: [(sql: String, args: Args?)]) -> Success {
        var err: NSError? = nil
        self.transaction(&err) { (conn, err) -> Bool in
            for (sql, args) in sql {
                err = conn.executeChange(sql, withArgs: args)
                if err != nil {
                    return false
                }
            }
            return true
        }

        if let err = err {
            return deferResult(DatabaseError(err: err))
        }

        return succeed()
    }

    func runQuery<T>(sql: String, args: Args?, factory: SDRow -> T) -> Deferred<Result<Cursor<T>>> {
        return runWithConnection { (connection, err) -> Cursor<T> in
            return connection.executeQuery(sql, factory: factory, withArgs: args)
        }
    }
}

extension SQLiteDBConnection {
    func tablesExist(names: Args) -> Bool {
        let count = names.count
        let orClause = join(" OR ", Array(count: count, repeatedValue: "name = ?"))
        let tablesSQL = "SELECT name FROM sqlite_master WHERE type = 'table' AND (\(orClause))"

        let res = self.executeQuery(tablesSQL, factory: StringFactory, withArgs: names)
        log.debug("\(res.count) tables exist. Expected \(count)")
        return res.count > 0
    }
}
