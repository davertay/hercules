import Foundation
import SQLiteData

/// Creates or opens a Workflow's SQLite database, applying migrations idempotently — safe on every
/// launch.
public func openWorkflowDatabase(at directory: URL) throws -> any DatabaseWriter {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("workflow.sqlite").path
    // The create-issue MCP server writes Issues from a separate process (ADR 0006) while the app streams
    // the live transcript into the same WAL database. SQLite allows only one writer at a time, so without
    // a busy timeout a contending `BEGIN IMMEDIATE` fails outright with "database is locked". Wait and
    // retry for a few seconds instead.
    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    let database = try defaultDatabase(path: path, configuration: configuration)
    var migrator = DatabaseMigrator()
    registerWorkflowMigrations(&migrator)
    try migrator.migrate(database)
    return database
}

func registerWorkflowMigrations(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("Create per-Workflow schema") { db in
        try #sql(
            """
            CREATE TABLE "workflow" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "repoPath" TEXT NOT NULL DEFAULT '',
              "createdAt" TEXT NOT NULL,
              "updatedAt" TEXT NOT NULL,
              "isDeleted" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
            ) STRICT
            """
        )
        .execute(db)

        try #sql(
            """
            CREATE TABLE "phase" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "workflowID" TEXT NOT NULL REFERENCES "workflow"("id") ON DELETE CASCADE,
              "kind" TEXT NOT NULL,
              "status" TEXT NOT NULL,
              "artifactPath" TEXT,
              "createdAt" TEXT NOT NULL,
              "updatedAt" TEXT NOT NULL,
              "isDeleted" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
            ) STRICT
            """
        )
        .execute(db)

        try #sql(
            """
            CREATE TABLE "session" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "workflowID" TEXT NOT NULL REFERENCES "workflow"("id") ON DELETE CASCADE,
              "worktreePath" TEXT NOT NULL,
              "mode" TEXT NOT NULL,
              "createdAt" TEXT NOT NULL,
              "updatedAt" TEXT NOT NULL,
              "isDeleted" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
            ) STRICT
            """
        )
        .execute(db)

        try #sql(
            """
            CREATE TABLE "turn" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "sessionID" TEXT NOT NULL REFERENCES "session"("id") ON DELETE CASCADE,
              "userPrompt" TEXT NOT NULL DEFAULT '',
              "finalAnswer" TEXT,
              "isError" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "durationMs" INTEGER,
              "costUSD" REAL,
              "createdAt" TEXT NOT NULL,
              "updatedAt" TEXT NOT NULL,
              "isDeleted" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
            ) STRICT
            """
        )
        .execute(db)

        try #sql(
            """
            CREATE TABLE "content_block" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "turnID" TEXT NOT NULL REFERENCES "turn"("id") ON DELETE CASCADE,
              "position" INTEGER NOT NULL,
              "role" TEXT NOT NULL,
              "kind" TEXT NOT NULL,
              "text" TEXT NOT NULL DEFAULT '',
              "createdAt" TEXT NOT NULL,
              "updatedAt" TEXT NOT NULL,
              "isDeleted" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
            ) STRICT
            """
        )
        .execute(db)

        try #sql(#"CREATE INDEX "index_phase_on_workflowID" ON "phase"("workflowID")"#)
            .execute(db)
        try #sql(#"CREATE INDEX "index_session_on_workflowID" ON "session"("workflowID")"#)
            .execute(db)
        try #sql(#"CREATE INDEX "index_turn_on_sessionID" ON "turn"("sessionID")"#)
            .execute(db)
        try #sql(#"CREATE INDEX "index_content_block_on_turnID" ON "content_block"("turnID")"#)
            .execute(db)
    }

    migrator.registerMigration("Add toolName to content_block") { db in
        try #sql(
            """
            ALTER TABLE "content_block" ADD COLUMN "toolName" TEXT
            """
        )
        .execute(db)
    }

    // ADR 0005. Pre-existing rows predate the split and could only have been Design, so default there.
    migrator.registerMigration("Add kind to session") { db in
        try #sql(
            """
            ALTER TABLE "session" ADD COLUMN "kind" TEXT NOT NULL DEFAULT 'design'
            """
        )
        .execute(db)
    }

    // Tags an Execute write Session with the Issue's `number` so its transcript is recoverable; null
    // for chat-surface Sessions.
    migrator.registerMigration("Add issueNumber to session") { db in
        try #sql(
            """
            ALTER TABLE "session" ADD COLUMN "issueNumber" INTEGER
            """
        )
        .execute(db)
    }

    // `dependencies` holds a JSON array of referenced per-Workflow `number`s — a field, not a join table.
    migrator.registerMigration("Create issue table") { db in
        try #sql(
            """
            CREATE TABLE "issue" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "workflowID" TEXT NOT NULL REFERENCES "workflow"("id") ON DELETE CASCADE,
              "number" INTEGER NOT NULL,
              "title" TEXT NOT NULL DEFAULT '',
              "body" TEXT NOT NULL DEFAULT '',
              "dependencies" TEXT NOT NULL DEFAULT '[]',
              "status" TEXT NOT NULL DEFAULT 'new',
              "createdAt" TEXT NOT NULL,
              "updatedAt" TEXT NOT NULL,
              "isDeleted" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
            ) STRICT
            """
        )
        .execute(db)

        try #sql(#"CREATE INDEX "index_issue_on_workflowID" ON "issue"("workflowID")"#)
            .execute(db)
    }

    // Captures why an Execute run of the Issue failed; null unless `status` is `failed`.
    migrator.registerMigration("Add failureReason to issue") { db in
        try #sql(
            """
            ALTER TABLE "issue" ADD COLUMN "failureReason" TEXT
            """
        )
        .execute(db)
    }

    // One row per (workflowID, kind), upserted per Validate run — no run history. Idle (never run) is the
    // absence of a row. `sessionID` forward-links the run's Session (a loose link, like `session.issueNumber`
    // — no FK). A partial unique index over the non-deleted rows enforces the one-row-per-Persona invariant
    // and doubles as the `workflowID` lookup index.
    migrator.registerMigration("Create review table") { db in
        try #sql(
            """
            CREATE TABLE "review" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "workflowID" TEXT NOT NULL REFERENCES "workflow"("id") ON DELETE CASCADE,
              "kind" TEXT NOT NULL,
              "status" TEXT NOT NULL,
              "summary" TEXT,
              "failureReason" TEXT,
              "sessionID" TEXT,
              "createdAt" TEXT NOT NULL,
              "updatedAt" TEXT NOT NULL,
              "isDeleted" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
            ) STRICT
            """
        )
        .execute(db)

        try #sql(
            #"""
            CREATE UNIQUE INDEX "index_review_on_workflowID_kind"
              ON "review"("workflowID", "kind") WHERE "isDeleted" = 0
            """#
        )
        .execute(db)
    }
}
