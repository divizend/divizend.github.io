import { Email } from "bentotools";

export default {
  reverser: (email: Email): string => {
    const text = email.text || email.html?.replace(/<[^>]*>/g, "") || "";
    return text.split("").reverse().join("");
  },
};
