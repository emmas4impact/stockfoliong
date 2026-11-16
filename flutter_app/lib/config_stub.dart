const _buildTimeApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://ngx-api.up.railway.app',
);

String configuredApiBaseUrl() => _buildTimeApiBaseUrl;
