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
        label: 'Server Update',
        value: 'server-update'
    },
    {
        label: 'New Server URL',
        value: 'new-server'
    },
    {
        label: 'Websocket Hello World',
        value: 'hello-world'
    }
];

export const scheduledMessageTypeOptions = [
    {
        label: 'Send Message',
        value: 'send-message'
    }
];

export const intervalTypeToLabel: Record<string, string> = {
    'hourly': 'Hour(s)',
    'daily': 'Day(s)',
    'weekly': 'Week(s)',
    'monthly': 'Month(s)',
    'yearly': 'Year(s)'
};