package cloudcore

import (
	"github.com/OpenListTeam/OpenList/v4/drivers/thunder"
	"github.com/gin-gonic/gin"
)

// JNI only, set before Start. Debug and Release both enable the beta provider.
func ConfigureThunder(enabled bool) { thunder.EnablePlayer(enabled) }
func thunderRoutes(router *gin.Engine) {
	router.POST("/thunder-auth", func(c *gin.Context) {
		var request thunder.PlayerLoginRequest
		if c.ShouldBindJSON(&request) != nil {
			c.JSON(200, gin.H{"code": 400, "message": "Invalid login fields"})
			return
		}
		result, err := thunder.PlayerLogin(c.Request.Context(), request)
		if err != nil {
			c.JSON(200, gin.H{"code": 500, "message": err.Error()})
			return
		}
		// This result stays inside native code. It is never a Godot snapshot.
		c.JSON(200, gin.H{"code": 200, "data": result})
	})
}
