package cloudcore

import (
	"github.com/OpenListTeam/OpenList/v4/drivers/guangya_open"
	"github.com/gin-gonic/gin"
)

func guangyaRoutes(router *gin.Engine) {
	router.POST("/guangya-auth", func(c *gin.Context) {
		var request guangya_open.PlayerAuthRequest
		if c.ShouldBindJSON(&request) != nil {
			c.JSON(200, gin.H{"code": 400, "message": "Invalid login fields"})
			return
		}
		result, err := guangya_open.PlayerAuth(c.Request.Context(), request)
		if err != nil {
			c.JSON(200, gin.H{"code": 500, "message": err.Error()})
			return
		}
		// The credential stays inside native code. It is never a Godot snapshot.
		c.JSON(200, gin.H{"code": 200, "data": result})
	})
}
