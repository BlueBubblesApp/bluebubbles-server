/* eslint-disable react/prefer-stateless-function */
import * as React from "react";
import "./LeftStatusIndicator.css";

class LeftStatusIndicator extends React.Component {
    render() {
        return (
            <div id="leftStatusBar">
                        <div id="statusColorIndicator" />
                        <svg id="restartIcon" viewBox="0 0 512 512">
                            <g>
                                <path d="M403.678,272c0,40.005-15.615,77.651-43.989,106.011C331.33,406.385,293.683,422,253.678,422
                                    c-40.005,0-77.651-15.615-106.011-43.989c-28.374-28.359-43.989-66.006-43.989-106.011s15.615-77.651,43.989-106.011
                                    C176.027,137.615,213.673,122,253.678,122c25.298,0,49.849,6.343,71.88,18.472L267.023,212h231.299L440.49,0l-57.393,70.13
                                    C344.323,45.14,299.865,32,253.678,32c-64.116,0-124.395,24.961-169.702,70.298C38.639,147.605,13.678,207.884,13.678,272
                                    s24.961,124.395,70.298,169.702C129.284,487.039,189.562,512,253.678,512s124.395-24.961,169.702-70.298
                                    c45.337-45.308,70.298-105.586,70.298-169.702v-15h-90V272z"/>
                            </g>
                        </svg>
                    </div>
        );
    }
}

export default LeftStatusIndicator;
