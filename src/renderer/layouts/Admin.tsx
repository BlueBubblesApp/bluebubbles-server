// React imports
import * as React from "react";
import { Switch, Route, Link, withRouter, RouteComponentProps } from "react-router-dom";
import * as Ago from "s-ago";

// Other imports
import clsx from "clsx";
import { ipcRenderer } from "electron";

// Material UI imports
import {
    createStyles,
    Theme,
    withStyles,
    StyleRules,
    createMuiTheme,
    MuiThemeProvider
} from "@material-ui/core/styles";
import ListItem from "@material-ui/core/ListItem";
import ListItemIcon from "@material-ui/core/ListItemIcon";
import ListItemText from "@material-ui/core/ListItemText";
import Drawer from "@material-ui/core/Drawer";
import AppBar from "@material-ui/core/AppBar";
import Toolbar from "@material-ui/core/Toolbar";
import List from "@material-ui/core/List";
import CssBaseline from "@material-ui/core/CssBaseline";
import Typography from "@material-ui/core/Typography";
import Divider from "@material-ui/core/Divider";
import IconButton from "@material-ui/core/IconButton";
import Badge from "@material-ui/core/Badge";
import Menu from "@material-ui/core/Menu";
import MenuItem from "@material-ui/core/MenuItem";
import ListSubheader from "@material-ui/core/ListSubheader";

// Material UI Icons
import {
    Menu as MenuIcon,
    ChevronLeft as ChevronLeftIcon,
    DeviceHub as DeviceIcon,
    Home as HomeIcon,
    Settings as SettingsIcon,
    BugReport as BugIcon,
    Notifications as NotificationsIcon,
    Warning as WarningIcon,
    Help as InfoIcon,
    CheckCircle as SuccessIcon,
    Error as ErrorIcon,
    Cached as CachedIcon,
    DiscFull as DiscFullIcon,
    AccessibilityNew as AccessibilityNewIcon
} from "@material-ui/icons";

// Custom Components
import Configuration from "@renderer/views/Configuration";
import Devices from "@renderer/views/Devices";
import Dashboard from "@renderer/views/Dashboard";
import Logs from "@renderer/views/Debug";
import Tutorial from "@renderer/views/Tutorial";

// Helpers
import { Config } from "@renderer/variables/types";

const CustomMuiTheme = createMuiTheme({
    palette: {
        type: "dark"
    }
});

const StyledMenuItem = withStyles(theme => ({
    root: {
        borderBottom: "1px solid grey",
        paddingTop: "5px",
        paddingBottom: "5px",
        "&:first-child": {
            paddingTop: 0
        },
        "&:last-child": {
            borderBottom: 0,
            paddingBottom: 0
        },
        minWidth: "500px"
    }
}))(MenuItem);

const alertIconMap: { [key: string]: JSX.Element } = {
    info: <InfoIcon />,
    warn: <WarningIcon />,
    error: <ErrorIcon />,
    success: <SuccessIcon />
};

interface Props {
    classes: any;
}

interface State {
    open: boolean;
    config: Config;
    alerts: any[];
    alertElement: HTMLElement;
    fdPerms: string;
    abPerms: string;
}

class AdminLayout extends React.Component<Props & RouteComponentProps, State> {
    state: State = {
        open: false,
        config: null,
        alerts: [],
        alertElement: null,
        fdPerms: "denied",
        abPerms: "denied"
    };

    async componentDidMount() {
        this.checkPermissions();
        try {
            const config = await ipcRenderer.invoke("get-config");
            if (config) this.setState({ config });
            const currentAlerts = await ipcRenderer.invoke("get-alerts");
            if (currentAlerts) this.setState({ alerts: currentAlerts });
        } catch (ex) {
            console.log("Failed to load database config & alerts");
        }

        ipcRenderer.on("config-update", (event, arg) => {
            this.setState({ config: arg });
        });

        ipcRenderer.on("new-alert", (event, alert) => {
            const { alerts } = this.state;
            if (!alert?.text || !alert?.type) return;

            // Insert at index 0, then concatenate to 10 items
            alerts.splice(0, 0, alert);
            if (alerts.length > 10) alerts.slice(0, 10);

            // Set the state
            this.setState({ alerts });
        });

        // Check for permissions every 10 seconds until we have permissions.. maybe?
        let interval: NodeJS.Timeout = null;
        if (this.state.abPerms !== "authorized" && this.state.fdPerms !== "authorized") {
            interval = setInterval(() => {
                this.checkPermissions();
                if (this.state.abPerms === "authorized" && this.state.fdPerms === "authorized") {
                    clearInterval(interval);
                }
            }, 10000);
        }
    }

    componentDidUpdate() {
        if (this.props.location.pathname === "/tutorial") return;

        // Check if the tutorial is done
        const tutorialIsDone = this.state.config?.tutorial_is_done;
        if (tutorialIsDone && !Number(tutorialIsDone)) {
            this.props.history.push("/tutorial");
        }
    }

    checkPermissions = async () => {
        const res = await ipcRenderer.invoke("check_perms");
        this.setState({
            abPerms: res.abPerms,
            fdPerms: res.fdPerms
        });
    };

    handleDrawerOpen = () => {
        this.setState({ open: true });
    };

    handleDrawerClose = () => {
        this.setState({ open: false });
    };

    handleAlertClose = async () => {
        this.setState({ alertElement: null });
        await ipcRenderer.invoke(
            "mark-alert-as-read",
            this.state.alerts.filter(item => !item.isRead).map(item => item.id)
        );

        // Mark all as read
        const newAlerts = this.state.alerts;
        for (const i of newAlerts) i.isRead = true;
        this.setState({ alerts: newAlerts });
    };

    markAlertAsRead = async (id: number) => {
        await ipcRenderer.invoke("mark-alert-as-read", [id]);

        // Mark individual as read
        const newAlerts = this.state.alerts;
        for (const i of newAlerts) if (i.id === id) i.isRead = true;
        this.setState({ alerts: newAlerts });
    };

    handleAlertOpen = (event: React.MouseEvent<HTMLElement>) => {
        this.setState({ alertElement: event.currentTarget });
    };

    renderAlerts = () => {
        const { classes } = this.props;
        return (
            <Menu
                anchorEl={this.state.alertElement}
                getContentAnchorEl={null}
                elevation={0}
                anchorOrigin={{ vertical: "bottom", horizontal: "left" }}
                id="alert-menu"
                keepMounted
                transformOrigin={{ vertical: "top", horizontal: "center" }}
                open={Boolean(this.state.alertElement)}
                onClose={() => this.handleAlertClose()}
            >
                {this.state.alerts.map(item => {
                    const typeIcon = alertIconMap[item.type];
                    const time = item.created ? Ago(item.created) : "N/A";
                    return (
                        <StyledMenuItem key={item.id} onClick={() => this.markAlertAsRead(item.id)}>
                            <section className={classes.alertBlock}>
                                <section className={classes.alertBody}>
                                    <section
                                        style={{ wordBreak: "break-word", whiteSpace: "normal", maxWidth: "425px" }}
                                    >
                                        <span>{item.value}</span>
                                    </section>
                                    <span>{typeIcon}</span>
                                </section>
                                <section className={classes.alertFooter}>
                                    <span style={{ textDecoration: item.isRead ? "none" : "underline" }}>
                                        {item.isRead ? "Already read" : "Mark as read"}
                                    </span>
                                    <span>{time}</span>
                                </section>
                            </section>
                        </StyledMenuItem>
                    );
                })}
            </Menu>
        );
    };

    render() {
        const { classes } = this.props;
        const { open, config, alerts } = this.state;
        const abColor = this.state.abPerms !== "authorized" ? classes.iconRed : classes.iconGreen;
        const fdColor = this.state.fdPerms !== "authorized" ? classes.iconRed : classes.iconGreen;

        return (
            <MuiThemeProvider theme={CustomMuiTheme}>
                <section className={classes.root}>
                    <CssBaseline />
                    <AppBar
                        position="fixed"
                        className={clsx(classes.appBar, {
                            [classes.appBarShift]: open
                        })}
                    >
                        <Toolbar>
                            <IconButton
                                color="inherit"
                                aria-label="open drawer"
                                onClick={() => this.handleDrawerOpen()}
                                edge="start"
                                className={clsx(classes.menuButton, {
                                    [classes.hide]: open
                                })}
                            >
                                <MenuIcon />
                            </IconButton>
                            <Typography variant="h6" noWrap>
                                BlueBubbles App
                            </Typography>
                            <section className={classes.grow} />
                            <IconButton
                                color="inherit"
                                aria-label={`show ${alerts.length} alerts`}
                                aria-controls="alert-menu"
                                aria-haspopup="true"
                                onClick={this.handleAlertOpen}
                            >
                                <Badge badgeContent={alerts.filter(item => !item.isRead).length} color="secondary">
                                    <NotificationsIcon />
                                </Badge>
                            </IconButton>
                        </Toolbar>
                    </AppBar>
                    <Drawer
                        variant="permanent"
                        className={clsx(classes.drawer, {
                            [classes.drawerOpen]: open,
                            [classes.drawerClose]: !open
                        })}
                        classes={{
                            paper: clsx({
                                [classes.drawerOpen]: open,
                                [classes.drawerClose]: !open
                            })
                        }}
                    >
                        <div className={classes.toolbar}>
                            <IconButton onClick={() => this.handleDrawerClose()}>
                                <ChevronLeftIcon />
                            </IconButton>
                        </div>
                        <Divider />
                        <List>
                            <ListItem
                                component={Link}
                                to="/"
                                button
                                className={clsx(classes.drawer, {
                                    [classes.listItemOpen]: open,
                                    [classes.listItemClosed]: !open
                                })}
                            >
                                <ListItemIcon>
                                    <HomeIcon />
                                </ListItemIcon>
                                <ListItemText primary="Welcome" />
                            </ListItem>
                            <ListItem
                                component={Link}
                                to="/devices"
                                button
                                className={clsx(classes.drawer, {
                                    [classes.listItemOpen]: open,
                                    [classes.listItemClosed]: !open
                                })}
                            >
                                <ListItemIcon>
                                    <DeviceIcon />
                                </ListItemIcon>
                                <ListItemText primary="Devices" />
                            </ListItem>
                        </List>
                        <Divider />
                        <List>
                            <ListItem
                                component={Link}
                                to="/debug"
                                button
                                className={clsx(classes.drawer, {
                                    [classes.listItemOpen]: open,
                                    [classes.listItemClosed]: !open
                                })}
                            >
                                <ListItemIcon>
                                    <BugIcon />
                                </ListItemIcon>
                                <ListItemText primary="Server Debugger" />
                            </ListItem>
                            <ListItem
                                component={Link}
                                to="/configuration"
                                button
                                className={clsx(classes.drawer, {
                                    [classes.listItemOpen]: open,
                                    [classes.listItemClosed]: !open
                                })}
                            >
                                <ListItemIcon>
                                    <SettingsIcon />
                                </ListItemIcon>
                                <ListItemText primary="Configuration" />
                            </ListItem>
                        </List>
                        <section className={classes.content}>&nbsp;</section>
                        <Divider />
                        <List
                            subheader={
                                <ListSubheader style={{ display: open ? "block" : "none" }} className={classes.header}>
                                    MacOS Permissions
                                </ListSubheader>
                            }
                        >
                            <ListItem
                                button
                                className={clsx(classes.drawer, {
                                    [classes.listItemOpen]: open,
                                    [classes.listItemClosed]: !open
                                })}
                            >
                                <ListItemIcon>
                                    <DiscFullIcon className={fdColor} />
                                </ListItemIcon>
                                <ListItemText primary="Full Disk" />
                            </ListItem>
                            <ListItem
                                button
                                className={clsx(classes.drawer, {
                                    [classes.listItemOpen]: open,
                                    [classes.listItemClosed]: !open
                                })}
                            >
                                <ListItemIcon>
                                    <AccessibilityNewIcon className={abColor} />
                                </ListItemIcon>
                                <ListItemText primary="Accessibility" />
                            </ListItem>
                            <ListItem
                                button
                                onClick={this.checkPermissions}
                                className={clsx(classes.drawer, {
                                    [classes.listItemOpen]: open,
                                    [classes.listItemClosed]: !open
                                })}
                            >
                                <ListItemIcon>
                                    <CachedIcon />
                                </ListItemIcon>
                                <ListItemText primary="Refresh" />
                            </ListItem>
                        </List>
                    </Drawer>
                    <section className={classes.container}>
                        <Switch>
                            <Route path="/tutorial">
                                <Tutorial config={config} />
                            </Route>
                            <Route path="/configuration">
                                <Configuration config={config} />
                            </Route>
                            <Route path="/devices">
                                <Devices />
                            </Route>
                            <Route path="/debug">
                                <Logs />
                            </Route>
                            <Route path="/">
                                <Dashboard />
                            </Route>
                        </Switch>
                    </section>
                </section>
                {this.renderAlerts()}
            </MuiThemeProvider>
        );
    }
}

const drawerWidth = 240;
const styles = (theme: Theme): StyleRules<string, {}> =>
    createStyles({
        grow: {
            flexGrow: 1
        },
        root: {
            display: "flex",
            marginBottom: "2em"
        },
        appBar: {
            zIndex: theme.zIndex.drawer + 1,
            transition: theme.transitions.create(["width", "margin"], {
                easing: theme.transitions.easing.sharp,
                duration: theme.transitions.duration.leavingScreen
            })
        },
        appBarShift: {
            marginLeft: drawerWidth,
            width: `calc(100% - ${drawerWidth}px)`,
            transition: theme.transitions.create(["width", "margin"], {
                easing: theme.transitions.easing.sharp,
                duration: theme.transitions.duration.enteringScreen
            })
        },
        menuButton: {
            marginRight: 36
        },
        hide: {
            display: "none"
        },
        drawer: {
            width: drawerWidth,
            flexShrink: 0,
            whiteSpace: "nowrap"
        },
        drawerOpen: {
            width: drawerWidth,
            transition: theme.transitions.create("width", {
                easing: theme.transitions.easing.sharp,
                duration: theme.transitions.duration.enteringScreen
            })
        },
        drawerClose: {
            transition: theme.transitions.create("width", {
                easing: theme.transitions.easing.sharp,
                duration: theme.transitions.duration.leavingScreen
            }),
            overflowX: "hidden",
            width: theme.spacing(7) + 1,
            [theme.breakpoints.up("sm")]: {
                width: theme.spacing(9) + 1
            }
        },
        toolbar: {
            display: "flex",
            alignItems: "center",
            justifyContent: "flex-end",
            padding: theme.spacing(0, 1),
            // necessary for content to be below app bar
            ...theme.mixins.toolbar
        },
        listItemClosed: {
            paddingLeft: "25px",
            [theme.breakpoints.down("xs")]: {
                paddingLeft: "16px"
            }
        },
        listItemOpen: {
            paddingLeft: "16px"
        },
        content: {
            flexGrow: 1,
            padding: theme.spacing(3)
        },
        container: {
            width: "100%",
            height: "100%",
            marginTop: "6em",
            marginLeft: "2em",
            marginRight: "2em"
        },
        alertBlock: {
            display: "flex",
            flexDirection: "column",
            width: "100%"
        },
        alertBody: {
            width: "100%",
            display: "flex",
            flexDirection: "row",
            alignItems: "flex-start",
            justifyContent: "space-between"
        },
        alertFooter: {
            marginTop: "10px",
            width: "100%",
            display: "flex",
            flexDirection: "row",
            alignItems: "flex-end",
            justifyContent: "space-between",
            fontSize: "14px",
            color: "lightgrey"
        },
        iconRed: {
            fill: "red"
        },
        iconGreen: {
            fill: "green"
        },
        header: {
            fontSize: "20px",
            color: "white"
        }
    });

export default withStyles(styles)(withRouter(AdminLayout));
