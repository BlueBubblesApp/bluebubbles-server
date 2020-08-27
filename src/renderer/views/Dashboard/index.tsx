/* eslint-disable */
import * as React from "react";
import { Redirect } from "react-router-dom";
import * as numeral from "numeral";
import { ipcRenderer } from "electron";

import { createStyles, Theme, withStyles, StyleRules } from "@material-ui/core/styles";

import { Typography } from "@material-ui/core";

import { Message, DateRange, Accessibility, Update, People, Image, PhotoAlbum, RateReview } from "@material-ui/icons";
import CardIcon from "@renderer/components/Card/CardIcon";
import CardFooter from "@renderer/components/Card/CardFooter";
import Card from "@renderer/components/Card/Card";
import CardHeader from "@renderer/components/Card/CardHeader";
import GridContainer from "@renderer/components/Grid/GridContainer";
import GridItem from "@renderer/components/Grid/GridItem";

interface Props {
    classes: any;
}

interface State {
    totalMsgCount: number;
    recentMsgCount: number;
    groupMsgCount: { name: string; count: number };
    individualMsgCount: { name: string; count: number };
    myMsgCount: number;
    imageCount: { name: string; count: number };
}

class Dashboard extends React.Component<Props, State> {
    state: State = {
        totalMsgCount: 0,
        recentMsgCount: 0,
        myMsgCount: 0,
        groupMsgCount: { name: "Loading...", count: 0 },
        individualMsgCount: { name: "Loading...", count: 0 },
        imageCount: { name: "Loading...", count: 0 }
    };

    async componentDidMount() {
        this.loadData();
    }

    formatNumber(value: number) {
        if (value > 1000) {
            return numeral(value).format("0.0a");
        } else {
            return value;
        }
    }

    loadData() {
        // Don't await these
        this.loadTotalMessageCount();
        this.loadRecentMessageCount();
        this.loadGroupChatCounts();
        this.loadIndividualChatCounts();
        this.loadMyMessageCount();
        this.loadChatImageCounts();
    }

    async loadGroupChatCounts() {
        try {
            const res = await ipcRenderer.invoke("get-group-message-counts");
            let top = this.state.groupMsgCount;
            res.forEach((item: any) => {
                if (item.message_count > top.count) top = { name: item.group_name, count: item.message_count };
            });

            this.setState({
                groupMsgCount: top
            });
        } catch (ex) {
            console.log("Failed to load database stats");
        }
    }

    async loadIndividualChatCounts() {
        try {
            const res = await ipcRenderer.invoke("get-individual-message-counts");
            let top = this.state.individualMsgCount;
            res.forEach((item: any) => {
                if (item.message_count > top.count)
                    top = {
                        name: item.chat_identifier,
                        count: item.message_count
                    };
            });

            this.setState({
                individualMsgCount: top
            });
        } catch (ex) {
            console.log("Failed to load database stats");
        }
    }

    async loadTotalMessageCount() {
        try {
            this.setState({
                totalMsgCount: await ipcRenderer.invoke("get-message-count")
            });
        } catch (ex) {
            console.log("Failed to load database stats");
        }
    }

    async loadChatImageCounts() {
        try {
            const res = await ipcRenderer.invoke("get-chat-image-count");
            let top = this.state.imageCount;
            res.forEach((item: any) => {
                const identifier = item.chat_identifier.startsWith("chat") ? item.group_name : item.chat_identifier;
                if (item.image_count > top.count) top = { name: identifier, count: item.image_count };
            });

            this.setState({ imageCount: top });
        } catch (ex) {
            console.log("Failed to load database stats");
        }
    }

    async loadRecentMessageCount() {
        try {
            const after = new Date();
            after.setDate(after.getDate() - 1);
            this.setState({
                recentMsgCount: await ipcRenderer.invoke("get-message-count", {
                    after
                })
            });
        } catch (ex) {
            console.log("Failed to load database stats");
        }
    }

    async loadMyMessageCount() {
        try {
            const after = new Date();
            after.setDate(after.getDate() - 1);
            this.setState({
                myMsgCount: await ipcRenderer.invoke("get-message-count", {
                    after,
                    before: null,
                    isFromMe: true
                })
            });
        } catch (ex) {
            console.log("Failed to load database stats");
        }
    }

    render() {
        const { classes } = this.props;

        return (
            <section className={classes.root}>
                <Typography variant="h3">Welcome!</Typography>
                <Typography variant="subtitle2">
                    This is the BlueBubbles Dashboard. You'll be to see the status of your server, as well as some cool
                    statistics about your iMessages!
                </Typography>
                <br />
                <Typography variant="h4">Stats</Typography>
                <Typography variant="subtitle2">
                    Don't worry, these stats do not leave your computer! They are derived from the chat database that
                    iMessage uses
                </Typography>
                <section className={classes.widgetContainer}>
                    <GridContainer>
                        <GridItem xs={12} sm={6} md={4}>
                            <Card>
                                <CardHeader color="warning" stats={true} icon={true}>
                                    <CardIcon color="warning">
                                        <Message />
                                    </CardIcon>
                                    <p className={classes.cardCategory}>Messages</p>
                                    <h3 className={classes.cardTitle}>{this.formatNumber(this.state.totalMsgCount)}</h3>
                                </CardHeader>
                                <CardFooter stats={true}>
                                    <div className={classes.stats}>
                                        <DateRange />
                                        All Time
                                    </div>
                                </CardFooter>
                            </Card>
                        </GridItem>
                        <GridItem xs={12} sm={6} md={4}>
                            <Card>
                                <CardHeader color="info" stats={true} icon={true}>
                                    <CardIcon color="info">
                                        <Message />
                                    </CardIcon>
                                    <p className={classes.cardCategory}>Recent Messages</p>
                                    <h3 className={classes.cardTitle}>
                                        {this.formatNumber(this.state.recentMsgCount)}
                                    </h3>
                                </CardHeader>
                                <CardFooter stats={true}>
                                    <div className={classes.stats}>
                                        <DateRange />
                                        Last 24 Hours
                                    </div>
                                </CardFooter>
                            </Card>
                        </GridItem>
                        <GridItem xs={12} sm={6} md={4}>
                            <Card>
                                <CardHeader color="danger" stats={true} icon={true}>
                                    <CardIcon color="danger">
                                        <People />
                                    </CardIcon>
                                    <p className={classes.cardCategory}>Top Group</p>
                                    <h3 className={classes.cardTitle}>{this.state.groupMsgCount.name}</h3>
                                </CardHeader>
                                <CardFooter stats={true}>
                                    <div className={classes.stats}>
                                        <Update />
                                        {this.formatNumber(this.state.groupMsgCount.count)} Messages
                                    </div>
                                </CardFooter>
                            </Card>
                        </GridItem>
                    </GridContainer>
                    <GridContainer>
                        <GridItem xs={12} sm={6} md={4}>
                            <Card>
                                <CardHeader color="warning" stats={true} icon={true}>
                                    <CardIcon color="warning">
                                        <Accessibility />
                                    </CardIcon>
                                    <p className={classes.cardCategory}>Best Friend</p>
                                    <h3 className={classes.cardTitle}>{this.state.individualMsgCount.name}</h3>
                                </CardHeader>
                                <CardFooter stats={true}>
                                    <div className={classes.stats}>
                                        <Update />
                                        {this.formatNumber(this.state.individualMsgCount.count)} Messages
                                    </div>
                                </CardFooter>
                            </Card>
                        </GridItem>
                        <GridItem xs={12} sm={6} md={4}>
                            <Card>
                                <CardHeader color="warning" stats={true} icon={true}>
                                    <CardIcon color="info">
                                        <PhotoAlbum />
                                    </CardIcon>
                                    <p className={classes.cardCategory}>Media Gurus</p>
                                    <h3 className={classes.cardTitle}>{this.state.imageCount.name}</h3>
                                </CardHeader>
                                <CardFooter stats={true}>
                                    <div className={classes.stats}>
                                        <Image />
                                        {this.formatNumber(this.state.imageCount.count)} Images Shared
                                    </div>
                                </CardFooter>
                            </Card>
                        </GridItem>
                        <GridItem xs={12} sm={6} md={4}>
                            <Card>
                                <CardHeader color="danger" stats={true} icon={true}>
                                    <CardIcon color="danger">
                                        <RateReview />
                                    </CardIcon>
                                    <p className={classes.cardCategory}>Textaholic</p>
                                    <h3 className={classes.cardTitle}>{this.formatNumber(this.state.myMsgCount)}</h3>
                                </CardHeader>
                                <CardFooter stats={true}>
                                    <div className={classes.stats}>
                                        <Update />
                                        Messages you sent today!
                                    </div>
                                </CardFooter>
                            </Card>
                        </GridItem>
                    </GridContainer>
                </section>
            </section>
        );
    }
}

const styles = (theme: Theme): StyleRules<string, {}> =>
    createStyles({
        root: {},
        header: {
            fontWeight: 400,
            marginBottom: "1em"
        },
        widgetContainer: {
            marginTop: "1em"
        },
        cardCategory: {
            color: "grey",
            margin: "0",
            fontSize: "16px",
            marginTop: "0",
            paddingTop: "10px",
            marginBottom: "0"
        },
        cardTitle: {
            color: "grey",
            marginTop: "0px",
            minHeight: "auto",
            fontWeight: 400,
            fontFamily: "'Roboto', 'Helvetica', 'Arial', sans-serif",
            marginBottom: "3px",
            textDecoration: "none",
            fontSize: "30px",
            "& small": {
                color: "grey",
                fontWeight: 400,
                lineHeight: 1
            }
        },
        statCard: {
            width: "250px"
        }
    });

export default withStyles(styles)(Dashboard);
