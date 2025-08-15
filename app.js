import express, { json, urlencoded } from "express";
import cors from "cors";
import Push from "node-pushover";
import dotenv from "dotenv";
dotenv.config();

const app = express();
const port = process.env.PORT || 8080; // Elastic Beanstalk는 8080 포트 사용

// Pushover 설정
const push = new Push({
  user: process.env.PUSHOVER_USER_KEY,
  token: process.env.PUSHOVER_API_TOKEN,
  onerror: function (error) {
    console.error("Pushover Error:", error);
  },
});

// 미들웨어
app.use(json({ limit: "10mb" }));
app.use(urlencoded({ extended: true }));

// CORS 설정
app.use(
  cors({
    origin: process.env.ALLOWED_ORIGINS
      ? process.env.ALLOWED_ORIGINS.split(",")
      : ["http://localhost:8000"], // 개발용
    credentials: true,
  })
);

// 헬스체크 엔드포인트 (Elastic Beanstalk용)
app.get("/", (req, res) => {
  res.json({
    message: "Contact API Server is running!",
    timestamp: new Date().toISOString(),
    version: "1.0.0",
  });
});

app.get("/health", (req, res) => {
  res.status(200).json({ status: "healthy" });
});

// Pushover 푸시 알림 전송 함수
async function sendPushNotification(name, message, phone) {
  return new Promise((resolve, reject) => {
    const body = `📩 문의 도착\n이름: ${name}\n전화: ${
      phone || "없음"
    }\n\n${message}`;
    push.send("새 문의 도착", body, (err, result) => {
      if (err) {
        console.error("Pushover 전송 실패:", err);
        reject(err);
      } else {
        console.log("Pushover 전송 성공:", result);
        resolve(result);
      }
    });
  });
}

// 문의사항 제출 엔드포인트
app.post("/api/contact", async (req, res) => {
  try {
    const { name, message, phone } = req.body;

    // 입력값 검증
    if (!name || !message) {
      return res.status(400).json({
        success: false,
        error: "이름, 메시지는 필수 입력 사항입니다.",
      });
    }

    // 스팸 방지: 메시지 길이 제한
    if (message.length > 1000) {
      return res.status(400).json({
        success: false,
        error: "메시지는 1000자 이내로 입력해주세요.",
      });
    }

    console.log("문의 접수:", {
      name,
      message: message.substring(0, 50) + "...",
    });

    // Pushover 푸시 알림 전송
    await sendPushNotification(name, message, phone);

    res.json({
      success: true,
      message: "문의사항이 성공적으로 전송되었습니다.",
      timestamp: new Date().toISOString(),
    });
  } catch (error) {
    console.error("문의 처리 오류:", error);
    res.status(500).json({
      success: false,
      error: "서버 오류가 발생했습니다. 잠시 후 다시 시도해주세요.",
    });
  }
});

// 에러 핸들링 미들웨어
app.use((error, req, res, next) => {
  console.error("Unhandled error:", error);
  res.status(500).json({
    success: false,
    error: "서버 내부 오류가 발생했습니다.",
  });
});

// 404 핸들러
app.use((req, res) => {
  res.status(404).json({
    success: false,
    error: "API 엔드포인트를 찾을 수 없습니다.",
  });
});

app.listen(port, () => {
  console.log(`✅ Contact API Server running on port ${port}`);
  console.log(`✅ Environment: ${process.env.NODE_ENV || "development"}`);
  console.log(
    `✅ Pushover configured: ${process.env.PUSHOVER_USER_KEY ? "YES" : "NO"}`
  );
});

export default app;
