## Function

```yaml
function handler(event) {
    var request = event.request;
    var uri = request.uri;
    
    // Extract the server identifier and the rest of the path
    var match = uri.match(/^\/server0([1-3])(\/.*)/);
    
    if (match) {
        var serverId = match[1];
        var newUri = match[2];
        
        // Rewrite the URI by removing the /server0* prefix
        request.uri = newUri;
        
        // Add a custom header with the server identifier
        request.headers['x-server-id'] = {value: 'server0' + serverId};
    }
    
    return request;
}
```

```yaml
function handler(event) {
    var request = event.request;
    var uri = request.uri;
    
    // Define your custom paths here
    var paths = {
        '/custom1': 'path1',
        '/custom2': 'path2',
        '/custom3': 'path3'
    };
    
    // Check if the URI starts with any of the custom paths
    for (var customPath in paths) {
        if (uri.startsWith(customPath)) {
            var pathId = paths[customPath];
            var newUri = uri.slice(customPath.length) || '/';
            
            // Rewrite the URI by removing the custom path prefix
            request.uri = newUri;
            
            // Add a custom header with the path identifier
            request.headers['x-path-id'] = {value: pathId};
            
            break;
        }
    }
    
    return request;
}
```