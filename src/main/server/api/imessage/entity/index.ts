import * as macosVersion from "macos-version";
import { Chat, ChatNew } from "./Chat";
import { Handle, HandleNew } from "./Handle";
import { Message, MessageNew } from "./Message";

const osVersion = macosVersion();
export const HandleEntity: typeof Handle | typeof HandleNew = osVersion >= "10.13.0" ? Handle : HandleNew;
export const ChatEntity: typeof Chat | typeof ChatNew = osVersion >= "10.13.0" ? Chat : ChatNew;
export const MessageEntity: typeof Message | typeof MessageNew = osVersion >= "10.13.0" ? Message : MessageNew;
