CREATE TABLE
    chat_message_join (
        chat_id INTEGER REFERENCES chat (ROWID) ON DELETE CASCADE,
        message_id INTEGER REFERENCES message (ROWID) ON DELETE CASCADE,
        message_date INTEGER DEFAULT 0,
        PRIMARY KEY (chat_id, message_id)
    );

CREATE INDEX chat_message_join_idx_message_id_only ON chat_message_join (message_id);

CREATE INDEX chat_message_join_idx_chat_id ON chat_message_join (chat_id);

CREATE INDEX chat_message_join_idx_message_date_id_chat_id ON chat_message_join (chat_id, message_date, message_id);

CREATE TRIGGER after_delete_on_chat_message_join AFTER DELETE ON chat_message_join BEGIN
UPDATE message
SET
    cache_roomnames = (
        SELECT
            group_concat (c.room_name)
        FROM
            chat c
            INNER JOIN chat_message_join j ON c.ROWID = j.chat_id
        WHERE
            j.message_id = OLD.message_id
    )
WHERE
    message.ROWID = OLD.message_id;

DELETE FROM message
WHERE
    message.ROWID = OLD.message_id
    AND OLD.message_id NOT IN (
        SELECT
            chat_message_join.message_id
        from
            chat_message_join
        WHERE
            chat_message_join.message_id = OLD.message_id
        LIMIT
            1
    )
    AND OLD.message_id NOT IN (
        SELECT
            chat_recoverable_message_join.message_id
        from
            chat_recoverable_message_join
        WHERE
            chat_recoverable_message_join.message_id = OLD.message_id
        LIMIT
            1
    );

END;

CREATE TRIGGER after_insert_on_chat_message_join AFTER INSERT ON chat_message_join BEGIN
UPDATE message
SET
    cache_roomnames = (
        SELECT
            group_concat (c.room_name)
        FROM
            chat c
            INNER JOIN chat_message_join j ON c.ROWID = j.chat_id
        WHERE
            j.message_id = NEW.message_id
    )
WHERE
    message.ROWID = NEW.message_id;

END;