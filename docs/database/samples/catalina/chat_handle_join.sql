CREATE TABLE chat_handle_join (
    chat_id INTEGER REFERENCES chat (ROWID) ON DELETE CASCADE,
    handle_id INTEGER REFERENCES handle (ROWID) ON DELETE CASCADE,
    UNIQUE(chat_id, handle_id)
)