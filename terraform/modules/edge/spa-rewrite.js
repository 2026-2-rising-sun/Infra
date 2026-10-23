// CloudFront Function (viewer-request). 확장자 없는 경로를 /index.html 로 바꿔 SPA 라우터가 처리하게 한다.
// /api/* 는 별도 behavior 라 이 함수를 타지 않는다. 파일 요청(/assets/app-abc.js 등)은 그대로 S3 로 간다.
function handler(event) {
  var request = event.request;
  var uri = request.uri;
  if (uri.endsWith('/')) {
    request.uri = uri + 'index.html';
  } else if (!uri.includes('.')) {
    request.uri = '/index.html';
  }
  return request;
}
