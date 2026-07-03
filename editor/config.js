// Songitude editor configuration. Filled in at deploy time.
// - googleClientId: a Google OAuth 2.0 "Web application" Client ID (…apps.googleusercontent.com)
//     with https://songitude.com (and http://localhost for dev) as Authorized JavaScript origins.
// - publishApiUrl: the Lambda Function URL that mints a presigned S3 upload URL.
// Until BOTH are real values, the editor runs open and the "Publish to app" button stays hidden.
window.SONGITUDE_CONFIG = {
  googleClientId: "656432234496-jt8jjsraquhlkf72qlq3obnq9uoapv26.apps.googleusercontent.com",
  publishApiUrl: "https://9pt6nx5b7f.execute-api.us-east-1.amazonaws.com/",
};
