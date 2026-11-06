//  MessageWireKeys
//  The serialized keys this server reads back as well as writes.
//
//  A serialized message is not only sent: the notification codecs read its GUID, chat,
//  sender and text back out of it for their clear-text hints, and the ntfy provider reads its
//  text for a notification body. Each of those keys is spelled ONCE, here, and both the
//  serializer that writes it and the reader that reads it use the constant. Renaming a field
//  in the serializer is then a rename of the constant, which carries the readers with it, or
//  a compile error if someone deletes it. Spelled as a literal on each side, a rename would
//  quietly blank every hint: the parity diff compares the serializer's output against the
//  recorded fixtures, and nothing compares it against what the codecs expect to find.
//
//  Only the keys something here reads back are named. The rest of the serializer's keys
//  stay literals at the one place they are written, which is where a reader of the wire
//  format looks for them.

import Foundation

/// Keys of a serialized message (`MessageSerializer`).
public enum MessageWireKey {
  public static let guid = "guid"
  public static let text = "text"
  public static let isFromMe = "isFromMe"
  public static let handle = "handle"
  public static let chats = "chats"
  /// Not written by `MessageSerializer`: the key a payload uses when it names its chat
  /// directly instead of nesting the chats, which the hint reader accepts first.
  public static let chatGuid = "chatGuid"
}

/// Keys of a serialized handle (`HandleSerializer`).
public enum HandleWireKey {
  public static let address = "address"
}

/// Keys of a serialized chat (`ChatSerializer`).
public enum ChatWireKey {
  public static let guid = "guid"
}
