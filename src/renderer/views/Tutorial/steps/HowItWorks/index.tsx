/* eslint-disable */
import * as React from "react";

import {
    createStyles,
    Theme,
    withStyles,
    StyleRules
} from "@material-ui/core/styles";

import { Typography } from "@material-ui/core";


interface Props {
    classes: any;
}

interface State {

}

class HowItWorks extends React.Component<Props, State> {
    render() {
        const { classes } = this.props;

        return (
            <section className={classes.root}>
                <Typography variant="h4" className={classes.header}>
                    How it Works
                </Typography>
                <Typography variant="subtitle2" className={classes.subtitle}>
                    The BlueBubbles Server acts as a middleman between your
                    iMessage chats and your Android phone. The application
                    listens for new messages, and forwards those messages to
                    your Android phone via Google's Firebase Cloud Messaging
                    Service and websockets. The BlueBubbles Server will also
                    listen for incoming messages from your Android phone, and
                    will send them to the specific recipient.
                </Typography>
                <Typography variant="h4" className={classes.subtitle}>
                    Your Mac, as a Server
                </Typography>
                <Typography variant="subtitle2">
                    As mentioned above, the BlueBubbles Server and the
                    BlueBubbles Android App communicate via Google FCM and
                    websockets. In order for the Android App to talk to the
                    server, the server needs to be internet-accessible. It does
                    this by utilizing a free software called "ngrok". This
                    software creates a secure tunnel between your Mac and the
                    internet. This connection is encrypted over HTTPS and allows
                    your phone to communicate with the server.
                </Typography>
            </section>
        );
    }
}

const styles = (theme: Theme): StyleRules<string, {}> =>
    createStyles({
        root: {
            marginTop: "0.5em"
        },
        header: {
            fontWeight: 400
        },
        subtitle: {
            marginTop: "0.5em"
        }
    });

export default withStyles(styles)(HowItWorks);
