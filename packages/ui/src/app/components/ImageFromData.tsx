import React from 'react';

type propTypes = React.DetailedHTMLProps<React.ImgHTMLAttributes<HTMLImageElement>, HTMLImageElement>;
export const ImageFromData = (props: { data: any } & propTypes) => <img src={`data:image/jpeg;base64,${props.data}`} {...props} />;