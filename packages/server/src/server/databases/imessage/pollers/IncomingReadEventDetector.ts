import type { DataSource } from "typeorm";

/**
 * Counts the incoming messages in a chat that are still awaiting a read.
 *
 * Only real messages count. `item_type != 0` rows are system events (group
 * renames, participant changes) and rows with an `associated_message_type` are
 * tapbacks and edits. Apple badges none of them,
 * but they keep `is_read = 0` indefinitely, so counting them leaves a chat
 * permanently unread.
 */
export function buildChatUnreadCountQuery(): string {
    return `
        SELECT
            COUNT(DISTINCT c.ROWID) AS chat_count,
            SUM(
                CASE
                    WHEN m.is_read = 0
                        AND m.date_read = 0
                        AND m.item_type = 0
                        AND COALESCE(m.associated_message_type, 0) = 0
                        AND m.is_from_me = 0
                    THEN 1
                    ELSE 0
                END
            ) AS unread_count
        FROM chat c
        LEFT JOIN chat_message_join j ON j.chat_id = c.ROWID
        LEFT JOIN message m ON m.ROWID = j.message_id
        WHERE c.guid = ?
    `;
}

/**
 * Resolves whether a single chat currently has no unread incoming messages.
 *
 * A read advancing on one message does not mean the chat is read: the user may
 * have read the newest message while older ones remain unread, and emitting an
 * unconditional `read: true` clears the whole badge. Re-check the chat instead.
 */
export async function isChatFullyRead(db: DataSource, guid: string): Promise<boolean> {
    const rows = await db.query(buildChatUnreadCountQuery(), [guid]);
    const chatCount = Number(rows?.[0]?.chat_count ?? 0);
    if (chatCount <= 0) return false;
    const unread = Number(rows[0]?.unread_count ?? 0);
    return unread === 0;
}
