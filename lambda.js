const express = require("express");
const { json, urlencoded } = require("express");
const serverlessExpress = require("@vendia/serverless-express");
const cors = require("cors");
const Push = require("node-pushover");
const dotenv = require("dotenv");

dotenv.config();

// Express 앱 초기화
const app = express();

// 허용된 오리진 목록 (하드코딩으로 보안 강화)
const ALLOWED_ORIGINS = [
  "https://yellow-parasol.com",
  "https://braces.fit",
  "http://localhost:8000", // Vite 기본 포트
];

// Pushover 설정 (환경 변수 사용)
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

// CORS 설정 강화
app.use(
  cors({
    origin: (origin, callback) => {
      console.log("요청 Origin:", origin);

      // 환경 변수에서 허용된 오리진도 가져오기
      const envAllowed = (process.env.ALLOWED_ORIGINS || "")
        .split(",")
        .map((o) => o.trim().replace(/\/$/, ""))
        .filter((o) => o.length > 0);

      // 모든 허용된 오리진 합치기
      const allAllowed = [...ALLOWED_ORIGINS, ...envAllowed];

      // origin이 undefined인 경우 (직접 API 호출, 모바일 앱 등)
      if (!origin) {
        console.log("Origin 없음 - 허용");
        return callback(null, true);
      }

      // 정규화 (끝 슬래시 제거)
      const normalizedOrigin = origin.replace(/\/$/, "");

      if (allAllowed.includes(normalizedOrigin)) {
        console.log("✅ CORS 허용:", origin);
        callback(null, true);
      } else {
        console.log("❌ CORS 거부:", origin, "허용된 목록:", allAllowed);
        callback(new Error("CORS not allowed"), false);
      }
    },
    credentials: true,
    methods: ["GET", "POST", "OPTIONS"],
    allowedHeaders: ["Content-Type", "Authorization", "X-Requested-With"],
    preflightContinue: false,
    optionsSuccessStatus: 200,
  })
);

// 추가 CORS 헤더 설정 미들웨어
app.use((req, res, next) => {
  const origin = req.get("Origin");
  const envAllowed = (process.env.ALLOWED_ORIGINS || "")
    .split(",")
    .map((o) => o.trim().replace(/\/$/, ""))
    .filter((o) => o.length > 0);

  const allAllowed = [...ALLOWED_ORIGINS, ...envAllowed];

  if (!origin || allAllowed.includes(origin.replace(/\/$/, ""))) {
    res.header("Access-Control-Allow-Origin", origin || "*");
    res.header("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    res.header(
      "Access-Control-Allow-Headers",
      "Content-Type, Authorization, X-Requested-With"
    );
    res.header("Access-Control-Allow-Credentials", "true");
  }

  if (req.method === "OPTIONS") {
    res.status(200).end();
    return;
  }

  next();
});

// 헬스체크 엔드포인트
app.get("/", (req, res) => {
  res.json({
    message: "Welcome to Contact API",
    version: "1.0.0",
    timestamp: new Date().toISOString(),
  });
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
    console.log("요청 수신 - Origin:", req.get("Origin"));
    console.log("요청 데이터:", {
      name: req.body?.name,
      phone: req.body?.phone,
      message: req.body?.message
        ? req.body.message.substring(0, 50) + "..."
        : undefined,
    });

    const { name, message, phone } = req.body;

    // 입력값 검증
    if (!name || !message) {
      return res.status(400).json({
        success: false,
        error: "이름, 메시지는 필수 입력 사항입니다.",
      });
    }

    if (typeof name !== "string" || typeof message !== "string") {
      return res.status(400).json({
        success: false,
        error: "올바르지 않은 데이터 형식입니다.",
      });
    }

    if (name.trim().length < 2) {
      return res.status(400).json({
        success: false,
        error: "이름은 최소 2글자 이상 입력해주세요.",
      });
    }

    if (message.trim().length < 10) {
      return res.status(400).json({
        success: false,
        error: "메시지는 최소 10글자 이상 입력해주세요.",
      });
    }

    if (message.length > 1000) {
      return res.status(400).json({
        success: false,
        error: "메시지는 1000자 이내로 입력해주세요.",
      });
    }

    console.log("문의 접수:", {
      name: name.trim(),
      message: message.substring(0, 50) + "...",
      phone: phone || "없음",
    });

    await sendPushNotification(name.trim(), message.trim(), phone?.trim());

    return res.json({
      success: true,
      message: "문의가 성공적으로 전송되었습니다.",
      timestamp: new Date().toISOString(),
    });
  } catch (err) {
    console.error("문의 처리 중 오류 발생:", err);
    return res.status(500).json({
      success: false,
      error: "문의 처리 중 서버 오류가 발생했습니다.",
    });
  }
});

// 에러 핸들링 미들웨어
app.use((error, req, res, next) => {
  console.error("전역 에러:", error);

  if (error.message === "CORS not allowed") {
    return res.status(403).json({
      success: false,
      error: "접근이 허용되지 않은 도메인입니다.",
    });
  }

  res.status(500).json({
    success: false,
    error: "서버 내부 오류가 발생했습니다.",
  });
});

// Serverless Express 핸들러를 내보냅니다.
exports.handler = serverlessExpress({ app });
