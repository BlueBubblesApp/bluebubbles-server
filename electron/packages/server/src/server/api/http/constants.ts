export const MessagesBasePath = `${process.env.HOME}/Library/Messages`;
export const invisibleMediaChar = String.fromCharCode(65532);

// Also modify packages/ui/src/app/constants.ts
export const webhookEventOptions = [
    {
        label: 'All Events',
        value: '*'
    },
    {
        label: 'New Messages',
        value: 'new-message'
    },
    {
        label: 'Message Updates',
        value: 'updated-message'
    },
    {
        label: 'Message Send Errors',
        value: 'message-send-error'
    },
    {
        label: 'Group Name Changes',
        value: 'group-name-change'
    },
    {
        label: 'Group Icon Changes',
        value: 'group-icon-changed'
    },
    {
        label: 'Group Icon Removal',
        value: 'group-icon-removed'
    },
    {
        label: 'Participant Removed',
        value: 'participant-removed'
    },
    {
        label: 'Participant Added',
        value: 'participant-added'
    },
    {
        label: 'Participant Left',
        value: 'participant-left'
    },
    {
        label: 'Chat Read Status Change',
        value: 'chat-read-status-changed'
    },
    {
        label: 'Typing Indicators',
        value: 'typing-indicator'
    },
    {
        label: 'Scheduled Message Errors',
        value: 'scheduled-message-error'
    },
    {
        label: 'Server Update',
        value: 'server-update'
    },
    {
        label: 'New Server URL',
        value: 'new-server'
    },
    {
        label: 'FindMy Location Update',
        value: 'new-findmy-location'
    },
    {
        label: 'Websocket Hello World',
        value: 'hello-world'
    },
    {
        label: 'Incoming Facetime Call',
        value: 'incoming-facetime'
    },
    {
        label: 'FaceTime Call Status Changed (Experimental)',
        value: 'ft-call-status-changed'
    },
    {
        label: 'iMessage Alias Removed',
        value: 'imessage-alias-removed'
    },
    {
        label: 'Theme Backup Created',
        value: 'theme-backup-created'
    },
    {
        label: 'Theme Backup Updated',
        value: 'theme-backup-updated'
    },
    {
        label: 'Theme Backup Deleted',
        value: 'theme-backup-deleted'
    },
    {
        label: 'Settings Backup Created',
        value: 'settings-backup-created'
    },
    {
        label: 'Settings Backup Updated',
        value: 'settings-backup-updated'
    },
    {
        label: 'Settings Backup Deleted',
        value: 'settings-backup-deleted'
    }
];