//  ChatDatabase
//  Where Messages keeps `chat.db`.
//
//  One answer, because two readers need it and must agree: the composition root opens and
//  watches the file, and the permission probe decides from it whether Full Disk Access has
//  been granted. A probe looking at a different path from the reader would report access
//  the server does not have, or the reverse. Resolved through
//  `ApplicationSupport.realHomeDirectory`, like every other path under the home directory.

import Foundation

public enum ChatDatabase {
  /// `~/Library/Messages/chat.db`.
  public static var defaultPath: String {
    ApplicationSupport.realHomeDirectory + "/Library/Messages/chat.db"
  }
}
