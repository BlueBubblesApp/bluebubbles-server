/* eslint-disable max-len */
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

        (* Iterate over recipients and add to list *)
        set members to {}
        repeat with targetRecipient in argv
            copy (buddy targetRecipient of service id targetService) to end of members
        end repeat

        (* Start the new chat with all the recipients *)
        set thisChat to make new text chat with properties {participants: members}
        log thisChat
    end tell

    tell application "System Events" to tell process "Messages" to set visible to false
end run`
};

/**
 * The AppleScript used to rename a group chat
 */
const renameGroupChat = {
    name: 'renameGroupChat.scpt',
    contents: `on run {currentName, newName}
    tell application "System Events"
        tell process "Messages"
            set groupMatch to -1
            
            (* Iterate over each chat row *)
            repeat with chatRow in ((table 1 of scroll area 1 of splitter group 1 of window 1)'s entire contents as list)
                if chatRow's class is row then
                    
                    (* Pull out the chat's name *)
                    set fullName to (chatRow's UI element 1)'s description
                    set nameSplit to my splitText(fullName, ". ")
                    set chatName to item 1 of nameSplit
                    
                    (* Only pull out groups *)
                    if chatName is equal to currentName then
                        set groupMatch to chatRow
                        exit repeat
                    end if
                end if
            end repeat
            
            (* If no match, exit *)
            if groupMatch is equal to -1 then
                tell me to error "Group chat does not exist"
            end if
            
            (* Select the chat and rename it *)
            select groupMatch
            try
                tell window 1 to tell splitter group 1 to tell button "Details"
                    try
                        (* If the popover is open, don't re-click Details *)
                        set popover to pop over 1
                    on error notOpen
                        (* If the popover is not open, click Details *)
                        click
                    end try

                    tell pop over 1 to tell scroll area 1 to tell text field 1
                        set value to newName
                        confirm
                    end tell
                    click
                end tell
            on error errorMessage
                tell me to error "execution error: Failed to rename group -> " & errorMessage
                key code 53
            end try
        end tell
    end tell
end run

on splitText(theText, theDelimiter)
    set AppleScript's text item delimiters to theDelimiter
    set theTextItems to every text item of theText
    set AppleScript's text item delimiters to ""
    return theTextItems
end splitText`
};

/**
 * AppleScript to add a participant to a group
 */
const addParticipant = {
    name: 'addParticipant.scpt',
    contents: `on run {currentName, participant}
    tell application "System Events"
        tell process "Messages"
            set groupMatch to -1
            
            (* Iterate over each chat row *)
            repeat with chatRow in ((table 1 of scroll area 1 of splitter group 1 of window 1)'s entire contents as list)
                if chatRow's class is row then
                    
                    (* Pull out the chat's name *)
                    set fullName to (chatRow's UI element 1)'s description
                    set nameSplit to my splitText(fullName, ". ")
                    set chatName to item 1 of nameSplit
                    
                    (* Only pull out groups *)
                    if chatName is equal to currentName then
                        set groupMatch to chatRow
                        exit repeat
                    end if
                end if
            end repeat
            
            if groupMatch is equal to -1 then
                tell me to error "Group chat does not exist"
            end if
            
            select groupMatch
            try
                tell window 1 to tell splitter group 1 to tell button "Details"
                    try
                        (* If the popover is open, don't re-click Details *)
                        set popover to pop over 1
                    on error notOpen
                        (* If the popover is not open, click Details *)
                        click
                    end try

                    tell pop over 1 to tell scroll area 1 to tell text field 2
                        set value to participant
                        set focused to true

                        (* We have to activate the window so that we can hit enter *)
                        tell application "Messages"
                            reopen
                            activate
                        end tell

                        key code 36 -- Enter
                    end tell
                end tell
                
                delay 1
                set totalWindows to count windows
                
                if totalWindows is greater than 1 then
                    repeat (totalWindows - 1) times
                        try
                            tell button 1 of window 1 to perform action "AXPress"
                        on error
                            exit repeat
                        end try
                    end repeat
                    log "Error: Not an iMessage address"
                    return
                end if
            on error errorMessage
                log errorMessage
                return
            end try
            
            key code 53 -- Escape
            log "success"
        end tell
    end tell
end run

on splitText(theText, theDelimiter)
	set AppleScript's text item delimiters to theDelimiter
	set theTextItems to every text item of theText
	set AppleScript's text item delimiters to ""
	return theTextItems
end splitText`
};

/**
 * AppleScript to add a participant to a group
 */
const removeParticipant = {
    name: 'removeParticipant.scpt',
    contents: `on run {currentName, address}
    tell application "System Events"
        tell process "Messages"
            set groupMatch to -1
            
            (* Iterate over each chat row *)
            repeat with chatRow in ((table 1 of scroll area 1 of splitter group 1 of window 1)'s entire contents as list)
                if chatRow's class is row then
                    
                    (* Pull out the chat's name *)
                    set fullName to (chatRow's UI element 1)'s description
                    set nameSplit to my splitText(fullName, ". ")
                    set chatName to item 1 of nameSplit
                    
                    (* Only pull out groups *)
                    if chatName is equal to currentName then
                        set groupMatch to chatRow
                        exit repeat
                    end if
                end if
            end repeat
            
            if groupMatch is equal to -1 then
                tell me to error "Group chat does not exist"
            end if
            
            select groupMatch
            try
                tell window 1 to tell splitter group 1 to tell button "Details"
                    try
                        (* If the popover is open, don't re-click Details *)
                        set popover to pop over 1
                    on error notOpen
                        (* If the popover is not open, click Details *)
                        click
                    end try

                    tell pop over 1 to tell scroll area 1
                        set contactRow to -1
                        repeat with participant in (table 1's entire contents) as list
                            if participant's class is row then
                                if name of participant's UI element 1 is equal to address then
                                    set contactRow to participant
                                    exit repeat
                                end if
                            end if
                        end repeat

                        (* We have to activate the window so that we can hit enter *)
                        tell application "Messages"
                            reopen
                            activate
                        end tell
                        
                        if contactRow is equal to -1 then
                            key code 53
                            log "Error: Address is not a participant"
                            return
                        end if
                        
                        select contactRow
                        delay 0.1
                        key code 51
                        delay 0.3
                        key code 53
                    end tell
                end tell

            on error errorMessage
                log errorMessage
            end try
        
            log "success"
        end tell
    end tell
end run

on splitText(theText, theDelimiter)
	set AppleScript's text item delimiters to theDelimiter
	set theTextItems to every text item of theText
	set AppleScript's text item delimiters to ""
	return theTextItems
end splitText`
};

export const AppleScripts = [sendMessage, startChat, renameGroupChat, addParticipant, removeParticipant];