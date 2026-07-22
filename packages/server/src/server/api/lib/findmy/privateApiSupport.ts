export const FIND_MY_PROCESS_IDENTIFIER = "com.apple.findmy";
export const MESSAGES_PROCESS_IDENTIFIER = "com.apple.MobileSMS";

type FindMyPrivateApiPlatform = {
    isMinBigSur: boolean;
    isMinSonoma: boolean;
    isMinSequoia: boolean;
};

export const resolveFindMyFriendsPrivateApiTarget = ({
    isMinBigSur,
    isMinSonoma,
    isMinSequoia
}: FindMyPrivateApiPlatform): string | null => {
    if (isMinSequoia) return FIND_MY_PROCESS_IDENTIFIER;
    if (isMinBigSur && !isMinSonoma) return MESSAGES_PROCESS_IDENTIFIER;
    return null;
};
