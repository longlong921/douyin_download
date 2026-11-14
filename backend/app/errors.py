class AppError(Exception):
    def __init__(self, code, message, status=502):
        self.code, self.message, self.status = code, message, status


def upstream_status(status):
    if status == 429:
        raise AppError('rate_limited', '抖音请求过于频繁，请稍后重试。', 429)
    if status in (401, 403):
        raise AppError('verification_required', '上游要求登录或验证，请先在抖音打开原链接；部署者可配置自己的有效 Cookie 后重试。')
    if status in (404, 410):
        raise AppError('unavailable', '视频不存在或已不可用，请在抖音确认作品是否公开。', 404)
    if status >= 400:
        raise AppError('upstream_error', '抖音服务暂时异常，请稍后重试。')
