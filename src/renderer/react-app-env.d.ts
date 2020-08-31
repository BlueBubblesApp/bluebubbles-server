// / <reference types="react-scripts" />
declare module "react-router-transition" {
    import { RouteProps } from "react-router";

    interface AnimatedSwitchProps {
        atEnter: React.CSSProperties;
        atLeave: React.CSSProperties;
        atActive: React.CSSProperties;
        didLeave?: (style: React.CSSProperties) => void;
        className?: string;
        wrapperComponent?: keyof HTMLElementTagNameMap;
        mapStyles?: (styles: React.CSSProperties) => React.CSSProperties;
        runOnMount?: boolean;
        children: React.ReactNode;
    }

    type AnimatedRouteProps = RouteProps;

    export const AnimatedSwitch: React.ComponentClass<AnimatedSwitchProps>;
    export const AnimatedRoute: React.ComponentClass<AnimatedRouteProps>;
    export const RouteTransition: React.ComponentClass<AnimatedSwitchProps>;
}
