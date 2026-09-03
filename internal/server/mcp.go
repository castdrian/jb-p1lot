package server

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"

	"github.com/castdrian/jb-p1lot/internal/registry"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func New(registryValue *registry.Registry) *mcp.Server {
	server := mcp.NewServer(&mcp.Implementation{Name: "jb-p1lot", Title: "jb-p1lot", Version: "0.1.3"}, &mcp.ServerOptions{
		Instructions: "Use the jb-p1lot MCP server with the jb-p1lot skill for exact targeting, visual and semantic UI flows, tweak cycles, debugging, and userspace-only recovery.",
		Logger:       slog.Default(),
	})
	for _, name := range registryValue.Names() {
		command, _ := registryValue.Get(name)
		schema, _ := json.Marshal(command.Schema)
		annotations := &mcp.ToolAnnotations{ReadOnlyHint: command.ReadOnly, IdempotentHint: command.ReadOnly}
		if command.Destructive {
			value := true
			annotations.DestructiveHint = &value
		}
		tool := &mcp.Tool{Name: command.Name, Description: command.Description, InputSchema: json.RawMessage(schema), Annotations: annotations}
		server.AddTool(tool, handler(registryValue, command.Name))
	}
	return server
}

func handler(registryValue *registry.Registry, name string) mcp.ToolHandler {
	return func(ctx context.Context, request *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		params, err := registry.ParseParams(request.Params.Arguments)
		if err != nil {
			return toolError(err), nil
		}
		device, _ := params["device"].(string)
		result, runErr := registryValue.Run(ctx, registry.Request{Command: name, Device: device, Params: params})
		if runErr != nil {
			return toolError(runErr), nil
		}
		return toolResult(result), nil
	}
}

func toolResult(result registry.Result) *mcp.CallToolResult {
	content := make([]mcp.Content, 0, 2)
	if result.Image != nil {
		content = append(content, &mcp.ImageContent{Data: result.Image, MIMEType: result.MIMEType})
	}
	if result.Data != nil || result.ArtifactPath != "" || result.SessionID != "" || result.URL != "" {
		payload := map[string]any{"data": result.Data}
		if result.ArtifactPath != "" {
			payload["artifactPath"] = result.ArtifactPath
		}
		if result.SessionID != "" {
			payload["sessionId"] = result.SessionID
		}
		if result.URL != "" {
			payload["url"] = result.URL
		}
		if result.Meta != nil {
			payload["meta"] = result.Meta
		}
		encoded, _ := json.Marshal(payload)
		content = append(content, &mcp.TextContent{Text: string(encoded)})
	}
	if len(content) == 0 {
		content = append(content, &mcp.TextContent{Text: "ok"})
	}
	return &mcp.CallToolResult{Content: content, StructuredContent: map[string]any{"data": result.Data, "artifactPath": result.ArtifactPath, "sessionId": result.SessionID, "url": result.URL, "meta": result.Meta}}
}

func toolError(err error) *mcp.CallToolResult {
	return &mcp.CallToolResult{IsError: true, Content: []mcp.Content{&mcp.TextContent{Text: fmt.Sprintf("%v", err)}}}
}

func Run(ctx context.Context, registryValue *registry.Registry) error {
	return New(registryValue).Run(ctx, &mcp.StdioTransport{})
}
