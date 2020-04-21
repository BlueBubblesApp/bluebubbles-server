type GetChatsRequest = {
    type: "getContacts";
};

type GetMessagesRequest = {
    type: "getMessages";
    chatIdentifier: string;
};
