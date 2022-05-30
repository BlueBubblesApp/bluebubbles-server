import { checkForIncomingFacetime10, checkForIncomingFacetime11 } from "@server/api/v1/apple/scripts";
import { Server } from "@server/index";
import { FileSystem } from "@server/fileSystem";
import { isMinBigSur } from "@server/helpers/utils";



export class FacetimeService {

    disableFacetimeListener = false;

    incomingCallListener: NodeJS.Timeout;

    static gettingCallPrev = false;
    static gettingCall = false;
    static notificationSent = false;


    start() {
        Server().log('Initializing Facetime Service');
        if (this.disableFacetimeListener) return;

        // Service loop
        const serviceLoop = async () => {
            if (this.disableFacetimeListener) return;
            
            // Check for call applescript
            let facetimeCallIncoming;
            if (isMinBigSur) {
                facetimeCallIncoming  = await (await FileSystem.executeAppleScript(checkForIncomingFacetime11())).replace('\n', ''); // If on macos 11 and up
            } else {
                facetimeCallIncoming  = await (await FileSystem.executeAppleScript(checkForIncomingFacetime10())).replace('\n', ''); // If on macos 10 and below
            }
            



            // Update the gettingCall variable if you're getting a call
            if (facetimeCallIncoming !== '')
                FacetimeService.gettingCall = true;
            else
                FacetimeService.gettingCall = false;
            


            // If you're getting a call, send a notification to the device
            if (FacetimeService.gettingCall && !FacetimeService.notificationSent) {
                Server().log(`Incoming facetime call from ${facetimeCallIncoming}`);
                FacetimeService.notificationSent = true;
                const jsonData = JSON.stringify({
                    "caller": facetimeCallIncoming,
                    "timestamp": Math.floor(+new Date() / 1000),
                })
                Server().emitMessage("incoming-facetime", jsonData);
            }


            // Clear the notification sent variable
            if (!FacetimeService.gettingCall && FacetimeService.notificationSent && FacetimeService.gettingCallPrev)
                FacetimeService.notificationSent = false;

            FacetimeService.gettingCallPrev = FacetimeService.gettingCall;

            setTimeout(serviceLoop, 1000);
        };

        setTimeout(serviceLoop, 0);
    }

    stop() {
        this.disableFacetimeListener = true;
    }

}