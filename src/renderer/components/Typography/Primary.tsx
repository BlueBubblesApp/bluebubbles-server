import * as React from "react";
// import PropTypes from "prop-types";
// @material-ui/core components
import withStyles from "@material-ui/core/styles/withStyles";
// core components
import typographyStyle from "../../assets/jss/material-dashboard-react/components/typographyStyle";

function Primary({ ...props }: any) {
    const { classes, children } = props;
    return <div className={`${classes.defaultFontStyle} ${classes.primaryText}`}>{children}</div>;
}

// Primary.propTypes = {
//   classes: PropTypes.object.isRequired
// };

export default withStyles(typographyStyle)(Primary);
