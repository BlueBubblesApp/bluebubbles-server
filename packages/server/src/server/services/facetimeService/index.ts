import { checkForIncomingFacetime10, checkForIncomingFacetime11 } from "@server/api/v1/apple/scripts";
import { Server } from "@server/index";
import { FileSystem } from "@server/fileSystem";
import { isMinBigSur } from "@server/helpers/utils";


export class FacetimeService {

    disableFacetimeListener = false;

    incomingCallListener: NodeJS.Timeout;


    start() {
        Server().log('Initializing Facetime Service');

        let gettingCall = false;
        let gettingCallPrev = false;
        let notificationSent = false;
        
        if (this.disableFacetimeListener) return;

        // Service loop
        const serviceLoop = async () => {
            if (this.disableFacetimeListener) return;
            
            // Check for call applescript
            let facetimeCallIncoming;
            if (isMinBigSur) {
                // eslint-disable-next-line max-len
                facetimeCallIncoming  = await (await FileSystem.executeAppleScript(checkForIncomingFacetime11())).replace('\n', ''); // If on macos 11 and up
            } else {
                // eslint-disable-next-line max-len
                facetimeCallIncoming  = await (await FileSystem.executeAppleScript(checkForIncomingFacetime10())).replace('\n', ''); // If on macos 10 and below
            }
            
            // Update the gettingCall variable if you're getting a call
            if (facetimeCallIncoming !== '')
                gettingCall = true;
            else
                gettingCall = false;
            
            // If you're getting a call, send a notification to the device
            if (gettingCall && !notificationSent) {
                Server().log(`Incoming facetime call from ${facetimeCallIncoming}`);
                notificationSent = true;
                const jsonData = JSON.stringify({
                    "caller": facetimeCallIncoming,
                    "timestamp": new Date().getTime(),
                })
                Server().emitMessage("incoming-facetime", jsonData);
            }

            // Clear the notification sent variable
            if (!gettingCall && notificationSent && gettingCallPrev)
                notificationSent = false;

            gettingCallPrev = gettingCall;

            setTimeout(serviceLoop, 1000);
        };

        setTimeout(serviceLoop, 0);
    }

    stop() {
        this.disableFacetimeListener = true;
    }

}