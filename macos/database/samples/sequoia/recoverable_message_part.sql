CREATE TABLE recoverable_message_part (
    chat_id INTEGER REFERENCES chat (ROWID) ON DELETE CASCADE,
    message_id INTEGER REFERENCES message (ROWID) ON DELETE CASCADE,
    part_index INTEGER,
    delete_date INTEGER,
    part_text BLOB NOT NULL,
    ck_sync_state INTEGER DEFAULT 0,
    PRIMARY KEY (chat_id, message_id, part_index),
    CHECK (delete_date != 0)
)