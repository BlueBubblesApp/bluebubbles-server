/* eslint-disable max-len */
import * as macosVersion from "macos-version";
import * as compareVersions from "compare-versions";
import { transports } from "electron-log";
import { FileSystem } from "@server/fileSystem";
import { escapeOsaExp } from "@server/helpers/utils";

const osVersion = macosVersion();

/**
 * The AppleScript used to send a message with or without an attachment
 */
export const startMessages = () => {
    return `set appName to "Messages"
        if application appName is running then
            return 0
        else
            tell application appName to reopen
        end if`;
};

/**
 * The AppleScript used to send a message with or without an attachment
 */
export const sendMessage = (chatGuid: string, message: string, attachment: string) => {
    if (!chatGuid || (!message && !attachment)) return null;

    let attachmentScpt = "";
    if (attachment && attachment.length > 0) {
        attachmentScpt = `set theAttachment to "${escapeOsaExp(attachment)}" as POSIX file
            send theAttachment to targetChat
            delay 0.5`;
    }

    let messageScpt = "";
    if (message && message.length > 0) {
        messageScpt = `send "${escapeOsaExp(message)}" to targetChat`;
    }

    return `tell application "Messages"
        set targetChat to a reference to chat id "${chatGuid}"

        ${attachmentScpt}
        ${messageScpt}
    end tell

    tell application "System Events" to tell process "Messages" to set visible to false`;
};

/**
 * The AppleScript used to restart iMessage
 */
export const restartMessages = () => {
    return `tell application "Messages"
        quit
        delay 0.5
        reopen
        delay 0.5
    end tell`;
};

/**
 * The AppleScript used to start a chat with some number of participants
 */
export const startChat = (participants: string[], service: string) => {
    const formatted = participants.map(buddy => `buddy "${buddy}" of targetService`);
    const buddies = formatted.join(", ");

    return `tell application "Messages"
        set targetService to 1st service whose service type = ${service}

        (* Start the new chat with all the recipients *)
        set thisChat to make new text chat with properties {participants: {${buddies}}}
        log thisChat
    end tell

    tell application "System Events" to tell process "Messages" to set visible to false`;
};

/**
 * The AppleScript used to rename a group chat
 */
export const openChat = (name: string) => {
    return `tell application "System Events"
        (* Check if messages was in the foreground *)
        set isForeground to false
        tell application "Finder"
            try
                set frontApp to window 1 of (first application process whose frontmost is true)
                set winName to name of frontApp
                if winName is equal to "Messages" then
                    set isForeground to true
                end if
            end try
        end tell

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
                    if chatName is equal to "${name}" then
                        set groupMatch to chatRow
                        exit repeat
                    end if
                end if
            end repeat
            
            (* If no match, exit *)
            if groupMatch is equal to -1 then
                tell me to error "Group chat does not exist"
            end if

            (* We have to activate the window so that we can hit enter *)
            tell application "Messages"
                reopen
                activate
            end tell
            delay 1
            
            (* Select the chat *)
            select groupMatch

        (* If the window was not in the foreground originally, hide it *)
        try
            if isForeground is equal to false then
                tell application "Finder"
                    set visible of process "Messages" to false
                end tell
            end if
        on error errorMsg
            (* Don't do anything *)
        end try
    end tell

    on splitText(theText, theDelimiter)
        set AppleScript's text item delimiters to theDelimiter
        set theTextItems to every text item of theText
        set AppleScript's text item delimiters to ""
        return theTextItems
    end splitText`;
};

/**
 * The AppleScript used to rename a group chat
 */
export const renameGroupChat = (currentName: string, newName: string) => {
    return `tell application "System Events"
        (* Check if messages was in the foreground *)
        set isForeground to false
        tell application "Finder"
            try
                set frontApp to window 1 of (first application process whose frontmost is true)
                set winName to name of frontApp
                if winName is equal to "Messages" then
                    set isForeground to true
                end if
            end try
        end tell

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
                    if chatName is equal to "${currentName}" then
                        set groupMatch to chatRow
                        exit repeat
                    end if
                end if
            end repeat
            
            (* If no match, exit *)
            if groupMatch is equal to -1 then
                tell me to error "Group chat does not exist"
            end if

            (* We have to activate the window so that we can hit enter *)
            tell application "Messages"
                reopen
                activate
            end tell
            delay 1
            
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
                        set value to "${newName}"
                        confirm
                    end tell
                    click
                end tell
            on error errorMessage
                tell me to error "execution error: Failed to rename group -> " & errorMessage
                key code 53
            end try
        end tell

        (* If the window was not in the foreground originally, hide it *)
        try
            if isForeground is equal to false then
                tell application "Finder"
                    set visible of process "Messages" to false
                end tell
            end if
        on error errorMsg
            (* Don't do anything *)
        end try
    end tell

    on splitText(theText, theDelimiter)
        set AppleScript's text item delimiters to theDelimiter
        set theTextItems to every text item of theText
        set AppleScript's text item delimiters to ""
        return theTextItems
    end splitText`;
};

/**
 * AppleScript to add a participant to a group
 */
export const addParticipant = (currentName: string, participant: string) => {
    return `tell application "System Events"
        (* Check if messages was in the foreground *)
        set isForeground to false
        tell application "Finder"
            try
                set frontApp to window 1 of (first application process whose frontmost is true)
                set winName to name of frontApp
                if winName is equal to "Messages" then
                    set isForeground to true
                end if
            end try
        end tell

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
                    if chatName is equal to "${currentName}" then
                        set groupMatch to chatRow
                        exit repeat
                    end if
                end if
            end repeat
            
            if groupMatch is equal to -1 then
                tell me to error "Group chat does not exist"
            end if

            (* We have to activate the window so that we can hit enter *)
            tell application "Messages"
                reopen
                activate
            end tell
            delay 1
            
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
                        set value to "${participant}"
                        set focused to true
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

        (* If the window was not in the foreground originally, hide it *)
        try
            if isForeground is equal to false then
                tell application "Finder"
                    set visible of process "Messages" to false
                end tell
            end if
        on error errorMsg
            (* Don't do anything *)
        end try
    end tell

    on splitText(theText, theDelimiter)
        set AppleScript's text item delimiters to theDelimiter
        set theTextItems to every text item of theText
        set AppleScript's text item delimiters to ""
        return theTextItems
    end splitText`;
};

/**
 * AppleScript to add a participant to a group
 */
export const removeParticipant = (currentName: string, address: string) => {
    return `tell application "System Events"
        (* Check if messages was in the foreground *)
        set isForeground to false
        tell application "Finder"
            try
                set frontApp to window 1 of (first application process whose frontmost is true)
                set winName to name of frontApp
                if winName is equal to "Messages" then
                    set isForeground to true
                end if
            end try
        end tell

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
                    if chatName is equal to "${currentName}" then
                        set groupMatch to chatRow
                        exit repeat
                    end if
                end if
            end repeat
            
            if groupMatch is equal to -1 then
                tell me to error "Group chat does not exist"
            end if

            (* We have to activate the window so that we can hit enter *)
            tell application "Messages"
                reopen
                activate
            end tell
            delay 1
            
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
                                if name of participant's UI element 1 is equal to "${address}" then
                                    set contactRow to participant
                                    exit repeat
                                end if
                            end if
                        end repeat
                        
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

        (* If the window was not in the foreground originally, hide it *)
        try
            if isForeground is equal to false then
                tell application "Finder"
                    set visible of process "Messages" to false
                end tell
            end if
        on error errorMsg
            (* Don't do anything *)
        end try
    end tell

    on splitText(theText, theDelimiter)
        set AppleScript's text item delimiters to theDelimiter
        set theTextItems to every text item of theText
        set AppleScript's text item delimiters to ""
        return theTextItems
    end splitText`;
};

/**
 * AppleScript to send a tap-back
 */
export const toggleTapback = (chatName: string, messageText: string, reactionIndex: number) => {
    return `tell application "System Events"
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
                    if chatName is equal to "${chatName}" then
                        set groupMatch to chatRow
                        exit repeat
                    end if
                end if
            end repeat
            
            (* If no match, exit *)
            if groupMatch is equal to -1 then
                tell me to error "Group chat does not exist"
            end if
            
            (* We have to activate the window so that we can hit enter *)
            tell application "Messages"
                reopen
                activate
            end tell
            delay 1
            
            (* Select the chat and rename it *)
            select groupMatch
            tell window 1 to tell splitter group 1
                set previousRow to null
                (* Get the text messages as a list and reverse it to get newest first *)
                set chatItems to reverse of (entire contents of scroll area 2 as list)
                
                (* Iterate over all the messages *)
                repeat with n from 1 to count of chatItems
                    set chatRow to (item n of chatItems)
                    
                    (* Check the types of the current row and previous row *)
                    if chatRow's class is static text and previousRow's class is group then
                        set textValue to chatRow's value
                        log textValue
                        (* Compare the text with what we are looking for *)
                        if textValue is equal to "${messageText}" then
                            select chatRow
                            tell previousRow to perform action "AXShowMenu"
                            delay 0.5
                            key code 125
                            keystroke return
                            delay 2.0
                            
                            (* Re-fetch the rows so we can get the tapback row *)
                            set newRows to reverse of (entire contents of scroll area 2 as list)
                            set tapBack to item (n + 1) of newRows
                            if tapBack's class is not radio group then
                                set tapBack to item (n - 1) of newRows
                            end if
                            tell radio button (${reactionIndex} as number) of tapBack to perform action "AXPress"
                            delay 0.5
                            keystroke return
                            
                            return
                        end if
                    end if
                    
                    set previousRow to chatRow
                end repeat
            end tell
        end tell
    end tell

    on splitText(theText, theDelimiter)
        set AppleScript's text item delimiters to theDelimiter
        set theTextItems to every text item of theText
        set AppleScript's text item delimiters to ""
        return theTextItems
    end splitText`;
};

/**
 * Checks if a typing indicator is present
 */
export const checkTypingIndicator = (chatName: string) => {
    return `tell application "System Events"
        set isTyping to false
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
                    if chatName is equal to "${chatName}" then
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
            tell window 1 to tell splitter group 1
                set previousRow to null
                (* Get the text messages as a list and reverse it to get newest first *)
                set chatItems to reverse of (entire contents of scroll area 2 as list)
                
                (* Check the 7th item. If it's an image, then it's the typing indicator *)
                set typingEl to (item 7 of chatItems)
                if typingEl's class is image then
                    set isTyping to true
                end if
            end tell
        end tell
        
        (* Return true/false *)
        log isTyping
    end tell

    on splitText(theText, theDelimiter)
        set AppleScript's text item delimiters to theDelimiter
        set theTextItems to every text item of theText
        set AppleScript's text item delimiters to ""
        return theTextItems
    end splitText`;
};

/**
 * Export contacts to a VCF file
 */
export const exportContacts = () => {
    let contactsApp = "Contacts";
    // If the OS Version is earlier than or equal to 10.7.0, use "Address Book"
    if (osVersion && compareVersions(osVersion, "10.7.0") <= 0) contactsApp = "Address Book";

    return `set contactsPath to POSIX file "${FileSystem.contactsDir}/AddressBook.vcf" as string
        tell application "${contactsApp}"
            quit
            delay 1.0
            reopen

            (* Create empty file *)
            set contactsFile to (open for access file contactsPath with write permission)

            try
                (* Add VCF contacts to file *)
                repeat with per in people
                    write ((vcard of per as text) & linefeed) to contactsFile
                end repeat

                (* Close the file *)
                close access contactsFile
            on error
                try
                    close access contactsFile
                on error
                    log "Failed to close contacts file"
                end try
            end try
        end tell`;
};

export const runTerminalScript = (path: string) => {
    return `tell application "Terminal" to do script "${escapeOsaExp(path)}"`;
};

export const openSystemPreferences = () => {
    return `tell application "System Preferences"
        reopen
        activate
    end tell`;
};

export const openLogs = () => {
    const logPath = transports.file.getFile().path;
    const pieces = logPath.split("/");
    const parent = pieces.slice(0, pieces.length - 1).join("/");
    return `do shell script "open ${parent}"`;
};
