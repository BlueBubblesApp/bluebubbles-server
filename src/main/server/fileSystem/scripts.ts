/**
 * The AppleScript used to send a message with or without an attachment
 */
const sendMessage = {
    name: "sendMessage.scpt",
    contents: `on run argv
    if (count of argv) >= 2 then
        set chatGuid to item 1 of argv
        set message to item 2 of argv

        tell application "Messages"
            set targetChat to a reference to text chat id chatGuid
            send message to targetChat

            if (count of argv) > 2 then
                set theAttachment to (item 3 of argv) as POSIX file
                send theAttachment to targetChat
            end if
        end tell

        tell application "System Events" to tell process "Messages" to set visible to false
    end if
end run`
};

/**
 * The AppleScript used to start a chat with some number of participants
 */
const startChat = {
    name: "startChat.scpt",
    contents: `on run argv
    tell application "Messages"
        set targetService to id of 1st service whose service type = iMessage

        set members to {}
        repeat with targetRecipient in argv
            copy (buddy targetRecipient of service id targetService) to end of members
        end repeat

        set thisChat to make new text chat with properties {participants: members}
        log thisChat
    end tell

    tell application "System Events" to tell process "Messages" to set visible to false
end run`
};

export const AppleScripts = [sendMessage, startChat];